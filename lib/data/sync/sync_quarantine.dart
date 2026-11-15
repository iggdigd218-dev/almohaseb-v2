import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../repository.dart';
import 'apply_remote.dart';
import 'conflict_resolver.dart';
import 'operation.dart';

/// مخزن الحجر الصحي للعمليات المتعارضة أو الناقصة الأب (sync_quarantine).
///
/// بدل إنشاء سجلات وهمية («صنف مؤقت» / «حساب مؤقت») أو مسح/دمج الكيانات
/// تلقائياً، تُعزل العملية في هذا الجدول وتُعاد معالجتها حتمياً فور وصول
/// الأب الحقيقي أو بتدخل المدير السيادي.
class SyncQuarantineStore {
  SyncQuarantineStore._();

  static const String kTable = 'sync_quarantine';
  static const String kReasonMissingParentFk = 'missing_parent_fk';
  static const String kReasonSovereignViolation = 'sovereign_authority_violation';
  static const String kReasonMemberItemCollision =
      'member_item_collision_owner_authority';
  static const String kReasonWorkspaceMismatch = 'workspace_mismatch';

  static Future<void> ensureTable(DatabaseExecutor ex) async {
    await ex.execute('''
      CREATE TABLE IF NOT EXISTS $kTable (
        op_id                TEXT PRIMARY KEY,
        workspace_id         TEXT NOT NULL DEFAULT 'default',
        device_id            TEXT NOT NULL DEFAULT '',
        entity_type          TEXT NOT NULL,
        entity_id            TEXT NOT NULL,
        op_type              TEXT NOT NULL,
        payload              TEXT NOT NULL DEFAULT '{}',
        op_json              TEXT NOT NULL,
        reason               TEXT NOT NULL,
        missing_parent_table TEXT DEFAULT '',
        missing_parent_id    TEXT DEFAULT '',
        details              TEXT DEFAULT '',
        status               TEXT NOT NULL DEFAULT 'pending',
        attempts             INTEGER NOT NULL DEFAULT 0,
        created_at           TEXT NOT NULL,
        updated_at           TEXT NOT NULL,
        resolved_at          TEXT DEFAULT ''
      )
    ''');
    try {
      await ex.execute(
        'CREATE INDEX IF NOT EXISTS idx_quarantine_status '
        'ON $kTable(status, updated_at)',
      );
      await ex.execute(
        'CREATE INDEX IF NOT EXISTS idx_quarantine_ws '
        'ON $kTable(workspace_id, status)',
      );
    } catch (_) {}
  }

  /// إدراج عملية في الحجر الصحي بشكل idempotent مع زيادة عداد المحاولات عند التكرار.
  static Future<void> quarantineOp(
    DatabaseExecutor txn, {
    required SyncOperation op,
    required String reason,
    String missingParentTable = '',
    String missingParentId = '',
    String details = '',
  }) async {
    await ensureTable(txn);
    final now = DateTime.now().toIso8601String();
    final existing = await txn.query(
      kTable,
      columns: ['attempts', 'created_at'],
      where: 'op_id = ?',
      whereArgs: [op.id],
      limit: 1,
    );
    final attempts = existing.isNotEmpty
        ? (((existing.first['attempts'] as num?)?.toInt() ?? 0) + 1)
        : 1;
    final createdAt = existing.isNotEmpty &&
            '${existing.first['created_at'] ?? ''}'.trim().isNotEmpty
        ? '${existing.first['created_at']}'
        : now;

    await txn.insert(
      kTable,
      {
        'op_id': op.id,
        'workspace_id': op.workspaceId,
        'device_id': op.deviceId,
        'entity_type': op.entityType.name,
        'entity_id': op.entityId,
        'op_type': op.opType.name,
        'payload': jsonEncode(op.payload),
        'op_json': op.toJson(),
        'reason': reason,
        'missing_parent_table': missingParentTable,
        'missing_parent_id': missingParentId,
        'details': details,
        'status': 'pending',
        'attempts': attempts,
        'created_at': createdAt,
        'updated_at': now,
        'resolved_at': '',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<Map<String, Object?>>> pendingOps(
    DatabaseExecutor ex, {
    String? workspaceId,
    String? reason,
  }) async {
    await ensureTable(ex);
    final clauses = <String>["status = 'pending'"];
    final args = <Object?>[];
    if (workspaceId != null && workspaceId.trim().isNotEmpty) {
      clauses.add('workspace_id = ?');
      args.add(workspaceId.trim());
    }
    if (reason != null && reason.trim().isNotEmpty) {
      clauses.add('reason = ?');
      args.add(reason.trim());
    }
    return ex.query(
      kTable,
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at ASC, op_id ASC',
    );
  }

  static Future<int> countPending(
    DatabaseExecutor ex, {
    String? workspaceId,
    String? reason,
  }) async {
    try {
      await ensureTable(ex);
      final clauses = <String>["status = 'pending'"];
      final args = <Object?>[];
      if (workspaceId != null && workspaceId.trim().isNotEmpty) {
        clauses.add('workspace_id = ?');
        args.add(workspaceId.trim());
      }
      if (reason != null && reason.trim().isNotEmpty) {
        clauses.add('reason = ?');
        args.add(reason.trim());
      }
      final rows = await ex.rawQuery(
        'SELECT COUNT(*) AS c FROM $kTable WHERE ${clauses.join(' AND ')}',
        args,
      );
      return (rows.firstOrNull?['c'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> markResolved(
    DatabaseExecutor ex,
    String opId, {
    String status = 'resolved',
  }) async {
    await ensureTable(ex);
    final now = DateTime.now().toIso8601String();
    await ex.update(
      kTable,
      {
        'status': status,
        'updated_at': now,
        'resolved_at': now,
      },
      where: 'op_id = ?',
      whereArgs: [opId],
    );
  }

  static Future<void> clearWorkspace(
    DatabaseExecutor ex,
    String workspaceId,
  ) async {
    try {
      await ensureTable(ex);
      await ex.delete(
        kTable,
        where: 'workspace_id = ?',
        whereArgs: [workspaceId],
      );
    } catch (_) {}
  }

  /// إعادة تشغيل العمليات المعزولة بسبب نقص السجل الأب (`missing_parent_fk`)
  /// تلقائياً بمجرد وصول السجل الأب الحقيقي إلى SQLite.
  static Future<int> autoReplayResolvedQuarantine(
    Repo repo, {
    String? workspaceId,
  }) async {
    final db = await repo.database;
    await ensureTable(db);
    final pending = await pendingOps(
      db,
      workspaceId: workspaceId,
      reason: kReasonMissingParentFk,
    );
    if (pending.isEmpty) return 0;

    var replayed = 0;
    final resolver = ConflictResolver();
    for (final qRow in pending) {
      final opId = '${qRow['op_id'] ?? ''}'.trim();
      final missingTable = '${qRow['missing_parent_table'] ?? ''}'.trim();
      final missingId = '${qRow['missing_parent_id'] ?? ''}'.trim();
      final opJsonRaw = '${qRow['op_json'] ?? ''}'.trim();
      if (opId.isEmpty || opJsonRaw.isEmpty) continue;

      if (missingTable.isNotEmpty && missingId.isNotEmpty) {
        try {
          final parentExists = await db.query(
            missingTable,
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [int.tryParse(missingId) ?? missingId],
            limit: 1,
          );
          if (parentExists.isEmpty) {
            continue;
          }
        } catch (e) {
          debugPrint('SyncQuarantineStore parent check error: $e');
        }
      }

      final SyncOperation op;
      try {
        op = SyncOperation.fromJson(opJsonRaw);
      } catch (e) {
        debugPrint('SyncQuarantineStore decode error for $opId: $e');
        continue;
      }

      try {
        final applied = await db.transaction((txn) async {
          final already = await txn.query(
            'operations',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [op.id],
            limit: 1,
          );
          if (already.isNotEmpty) {
            await markResolved(txn, op.id);
            return false;
          }
          final ok = await repo.applyRemoteOperation(txn, op, resolver);
          if (ok) {
            await markResolved(txn, op.id);
          }
          return ok;
        });
        if (applied) replayed++;
      } catch (e) {
        debugPrint('SyncQuarantineStore replay error for $opId: $e');
      }
    }
    return replayed;
  }
}

/// حارس السيادة: يمنع أي جهاز فرعي (عضو) من تعديل المستخدمين أو الصلاحيات أو
/// إعدادات هوية المنشأة السيادية الخاصة بالمالك.
class SovereignAuthorityGuard {
  SovereignAuthorityGuard._();

  static const Set<String> sovereignOrgSettingKeys = {
    'managerName',
    'profile.owner_name',
    'ownerDeviceId',
    'creatorDeviceId',
    'owner_email',
    'admin_pin',
    'auth_pin',
    'workspace_license',
    'subscription_tier',
  };

  /// تحديد ما إذا كانت العملية تمس صلاحيات أو هوية سيادية للمنشأة.
  static bool isSovereignMutation(SyncOperation op) {
    if (op.entityType == EntityKind.user ||
        op.entityType == EntityKind.userPermission) {
      return true;
    }
    if (op.entityType == EntityKind.setting &&
        sovereignOrgSettingKeys.contains(op.entityId)) {
      return true;
    }
    return false;
  }

  /// التحقق مما إذا كان الجهاز المرسل يملك صلاحية السيادة.
  static Future<bool> isSenderAuthorizedOwner(
    DatabaseExecutor txn,
    SyncOperation op, {
    String? ownDeviceId,
  }) async {
    final senderId = op.deviceId.trim();
    if (senderId.isEmpty) return false;

    String ownerMetaId = '';
    String wsMode = '';
    String creatorId = '';
    try {
      final metaRows = await txn.query(
        'sync_meta',
        columns: ['key', 'value'],
        where: "key IN ('ownerDeviceId', 'workspaceMode')",
      );
      for (final r in metaRows) {
        final k = '${r['key'] ?? ''}'.trim();
        final v = '${r['value'] ?? ''}'.trim();
        if (k == 'ownerDeviceId') ownerMetaId = v;
        if (k == 'workspaceMode') wsMode = v;
      }
    } catch (_) {}
    try {
      final stRows = await txn.query(
        'settings',
        columns: ['value'],
        where: "key = 'creatorDeviceId'",
        limit: 1,
      );
      if (stRows.isNotEmpty) {
        creatorId = '${stRows.first['value'] ?? ''}'.trim();
      }
    } catch (_) {}

    final ownerDevIds = <String>{};
    bool senderKnownNonOwner = false;
    bool senderKnownOwner = false;
    try {
      final devs = await txn.query(
        'devices',
        columns: ['id', 'is_owner'],
      );
      for (final d in devs) {
        final dId = '${d['id'] ?? ''}'.trim();
        final isOwner = ((d['is_owner'] as num?)?.toInt() ?? 0) == 1;
        if (isOwner && dId.isNotEmpty) {
          ownerDevIds.add(dId);
        }
        if (dId == senderId) {
          if (isOwner) {
            senderKnownOwner = true;
          } else {
            senderKnownNonOwner = true;
          }
        }
      }
    } catch (_) {}

    if (senderKnownNonOwner) {
      return false;
    }
    if (senderKnownOwner) {
      return true;
    }

    final localId = (ownDeviceId ?? '').trim();
    final localIsHostOrOwner = wsMode == 'host' ||
        (localId.isNotEmpty &&
            (ownerDevIds.contains(localId) || ownerMetaId == localId));

    // إذا كان هذا الجهاز هو المالك أو المضيف، يُحظر أي طرف آخر غير مسجل كمالك.
    if (localIsHostOrOwner) {
      return senderId == localId ||
          ownerDevIds.contains(senderId) ||
          (ownerMetaId.isNotEmpty && senderId == ownerMetaId);
    }

    // إذا كانت المنشأة تعرف مالكها مسبقاً (ownerDeviceId / creatorDeviceId / devices.is_owner=1)
    if (ownerMetaId.isNotEmpty ||
        creatorId.isNotEmpty ||
        ownerDevIds.isNotEmpty) {
      if (ownerDevIds.contains(senderId)) return true;
      if (ownerMetaId.isNotEmpty && senderId == ownerMetaId) return true;
      if (creatorId.isNotEmpty && senderId == creatorId) return true;
      return false;
    }

    // في وضع العضو الصريح دون سجل مالك معروف محلياً: نغلق الباب أمام الكتابات السيادية المجهولة.
    if (wsMode == 'member') {
      return false;
    }

    // في الوضع المستقل الصرف بلا أي أجهزة أخرى مسجلة (مثل اختبارات الوحدات المعزولة)
    return true;
  }
}
