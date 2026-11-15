import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../backup_engine.dart';
import '../repository.dart';
import 'apply_remote.dart';
import 'operation.dart';
import 'subscription_guard.dart';
import 'sync_engine.dart';

/// معاينة الأضرار والعمليات القابلة للاسترجاع في كتالوج الأصناف قبل التنفيذ.
class RecoveryPreview {
  final int autoMergeMovesCount;
  final int affectedCanonicalItemsCount;
  final int softDeletedItemsCount;
  final int recoverableHardDeletedItemsCount;
  final List<String> mergedConflictKeys;
  final List<String> sampleItemNames;

  const RecoveryPreview({
    required this.autoMergeMovesCount,
    required this.affectedCanonicalItemsCount,
    required this.softDeletedItemsCount,
    required this.recoverableHardDeletedItemsCount,
    required this.mergedConflictKeys,
    required this.sampleItemNames,
  });

  bool get hasRecoverableIssues =>
      autoMergeMovesCount > 0 ||
      softDeletedItemsCount > 0 ||
      recoverableHardDeletedItemsCount > 0 ||
      mergedConflictKeys.isNotEmpty;

  int get totalRecoverableCount =>
      autoMergeMovesCount +
      softDeletedItemsCount +
      recoverableHardDeletedItemsCount;
}

/// نتيجة تنفيذ استرجاع الأصناف أو فك الدمج التلقائي.
class CatalogRecoveryResult {
  final int restoredItems;
  final int revertedQtyMoves;
  final int resetConflicts;
  final int restoredSections;
  final int restoredCategories;
  final int queuedSyncOps;
  final String safetyBackupPath;

  const CatalogRecoveryResult({
    required this.restoredItems,
    required this.revertedQtyMoves,
    required this.resetConflicts,
    this.restoredSections = 0,
    this.restoredCategories = 0,
    required this.queuedSyncOps,
    required this.safetyBackupPath,
  });
}

/// خدمة استرجاع كتالوج الأصناف وإلغاء عمليات الدمج التلقائي (للمالك فقط).
///
/// مصممة لاستعادة الأصناف المفقودة أو المدمجة تلقائياً أو المحذوفة أثناء
/// تعارضات الانضمام السابقة، مع الحفاظ التام على جميع الفواتير والقيود
/// المحاسبية والعمليات المسجلة بعد الانضمام.
class CatalogRecoveryService {
  CatalogRecoveryService._();

  static Future<void> _ensureOwnerOrStandalone(Repo repo) async {
    final isOwner = await repo.isWorkspaceOwner();
    final mode = await repo.workspaceMode();
    if (!isOwner && mode != 'standalone') {
      throw StateError(
        'استرجاع الأصناف وإلغاء الدمج متاح حصراً لمدير المنشأة (المالك).',
      );
    }
  }

  static Future<String> _createSafeSnapshotIfFileBacked(Repo repo) async {
    try {
      final db = await repo.database;
      final path = db.path;
      if (path.isEmpty ||
          path == ':memory:' ||
          path.contains('in_memory')) {
        return '';
      }
      final file = await BackupEngine.createSafetySnapshotBeforeRestore(repo);
      return file.path;
    } catch (_) {
      return '';
    }
  }

  /// المعاينة الآمنة: تم تعطيل الاسترجاع الجماعي التلقائي لحماية أرصدة الحركات وسجل المحذوفات.
  static Future<RecoveryPreview> previewRecovery(Repo repo) async {
    return const RecoveryPreview(
      autoMergeMovesCount: 0,
      affectedCanonicalItemsCount: 0,
      softDeletedItemsCount: 0,
      recoverableHardDeletedItemsCount: 0,
      mergedConflictKeys: <String>[],
      sampleItemNames: <String>[],
    );
  }

  /// مُعطَّل نهائياً: يُمنع إحياء الأصناف المحذوفة ناعماً أو تعديل أرصدة المخزون تلقائياً بشكل جماعي أعمى.
  static Future<CatalogRecoveryResult> undoAutoMerges(
    Repo repo, {
    bool syncToGroup = true,
  }) async {
    throw UnsupportedError(
      'تم تعطيل أداة الاسترجاع الجماعي التلقائي (undoAutoMerges) نهائياً لمنع إحياء الأصناف المحذوفة أو الإخلال بأرصدة الحركات الحقيقية.',
    );
  }

  /// استرجاع جراحي لكتالوج الأصناف والأقسام والفئات من نسخة احتياطية (.nexora أو JSON)
  /// دون المساس بأي فواتير أو حسابات أو قيود مسجلة بعد الانضمام.
  static Future<CatalogRecoveryResult> restoreCatalogFromBackup(
    Repo repo,
    File backupFile, {
    SyncEngine? engine,
    SubscriptionState? sub,
    bool syncToGroup = true,
  }) async {
    await _ensureOwnerOrStandalone(repo);

    if (!await backupFile.exists()) {
      throw const BackupRestoreException('ملف النسخة الاحتياطية غير موجود.');
    }
    final rawBytes = await backupFile.readAsBytes();
    const sqliteMagic = 'SQLite format 3\x00';
    final isRawSqlite = rawBytes.length >= sqliteMagic.length &&
        utf8.decode(rawBytes.take(16).toList(), allowMalformed: true) ==
            sqliteMagic;

    BackupInspectionResult? inspection;
    if (!isRawSqlite) {
      inspection = await BackupEngine.inspectBackupBytes(
        repo,
        rawBytes,
        engine: engine,
        sub: sub,
        enforceSyncGuard: false,
        allowCrossWorkspace: true,
      );
    }

    try {
      final sectionsList = <Map<String, Object?>>[];
      final categoriesList = <Map<String, Object?>>[];
      final itemsList = <Map<String, Object?>>[];

      final File? sqliteFile =
          isRawSqlite ? backupFile : inspection?.extractedDbFile;
      if (sqliteFile != null) {
        Database? srcDb;
        try {
          srcDb = await databaseFactory.openDatabase(
            sqliteFile.path,
            options: OpenDatabaseOptions(readOnly: true),
          );
          try {
            sectionsList.addAll(
              (await srcDb.query('sections')).map(Map<String, Object?>.from),
            );
          } catch (_) {}
          try {
            categoriesList.addAll(
              (await srcDb.query('item_categories'))
                  .map(Map<String, Object?>.from),
            );
          } catch (_) {}
          try {
            itemsList.addAll(
              (await srcDb.query('items')).map(Map<String, Object?>.from),
            );
          } catch (_) {}
        } finally {
          if (srcDb != null && srcDb.isOpen) {
            try {
              await srcDb.close();
            } catch (_) {}
          }
        }
      } else if (inspection?.legacyJsonPayload != null) {
        final root = inspection!.legacyJsonPayload!;
        final dataObj =
            root['data'] is Map ? Map<String, Object?>.from(root['data'] as Map) : root;
        for (final e in (dataObj['sections'] as List? ?? const [])) {
          if (e is Map) sectionsList.add(Map<String, Object?>.from(e));
        }
        for (final e in (dataObj['item_categories'] as List? ?? const [])) {
          if (e is Map) categoriesList.add(Map<String, Object?>.from(e));
        }
        for (final e in (dataObj['items'] as List? ?? const [])) {
          if (e is Map) itemsList.add(Map<String, Object?>.from(e));
        }
      }

      if (itemsList.isEmpty && categoriesList.isEmpty && sectionsList.isEmpty) {
        throw const BackupRestoreException(
          'النسخة الاحتياطية المختارة لا تحتوي على بيانات كتالوج أصناف قابلة للاسترجاع.',
        );
      }

      final safetyPath = await _createSafeSnapshotIfFileBacked(repo);
      final db = await repo.database;
      final wsId = repo.requireWorkspaceId;
      final nowIso = DateTime.now().toIso8601String();

      var restoredSections = 0;
      var restoredCategories = 0;
      var restoredItems = 0;
      var queuedSyncOps = 0;
      final touchedSectionIds = <int>[];
      final touchedCategoryIds = <int>[];
      final touchedItemIds = <int>[];

      await db.transaction((txn) async {
        // 1) استرجاع الأقسام غير المحذوفة في النسخة
        for (final s in sectionsList) {
          final id = (s['id'] as num?)?.toInt();
          final name = '${s['name'] ?? ''}'.trim();
          final deletedAt = '${s['deleted_at'] ?? ''}'.trim();
          if (id == null || id <= 0 || name.isEmpty || deletedAt.isNotEmpty) {
            continue;
          }
          await txn.insert(
            'sections',
            {
              'id': id,
              'workspace_id': wsId,
              'name': name,
              'icon': '${s['icon'] ?? ''}',
              'icon_key': '${s['icon_key'] ?? ''}',
              'color_hex': '${s['color_hex'] ?? ''}',
              'image_path': '${s['image_path'] ?? ''}',
              'sort_order': (s['sort_order'] as num?)?.toInt() ?? 0,
              'deleted_at': '',
              'created_at': '${s['created_at'] ?? nowIso}'.trim().isEmpty
                  ? nowIso
                  : '${s['created_at']}',
              'updated_at': nowIso,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          restoredSections++;
          touchedSectionIds.add(id);
        }

        // 2) استرجاع فئات الأصناف (الجذور أولاً ثم الفرعية) مع تجنب تعارض الفهرس الفريد
        final activeCats = categoriesList.where((c) {
          final id = (c['id'] as num?)?.toInt() ?? 0;
          final name = '${c['name'] ?? ''}'.trim();
          final del = '${c['deleted_at'] ?? ''}'.trim();
          return id > 0 && name.isNotEmpty && del.isEmpty;
        }).toList()
          ..sort((a, b) {
            final pa = (a['parent_id'] as num?)?.toInt() ?? 0;
            final pb = (b['parent_id'] as num?)?.toInt() ?? 0;
            return pa.compareTo(pb);
          });

        for (final c in activeCats) {
          final id = (c['id'] as num?)!.toInt();
          final name = '${c['name'] ?? ''}'.trim();
          final rawParentId = (c['parent_id'] as num?)?.toInt();
          final safeParentId =
              await _resolveValidCategoryId(txn, rawParentId, excludeId: id);
          final safeSecId =
              await _resolveValidSectionId(txn, (c['section_id'] as num?)?.toInt());

          // إزالة تعارض الاسم تحت نفس الأب قبل الاستبدال إن كان منشأً أثناء التعارض
          final colliding = await txn.rawQuery('''
            SELECT id, name FROM item_categories
            WHERE COALESCE(parent_id, 0) = ?
              AND LOWER(name) = LOWER(?)
              AND id != ?
          ''', [safeParentId ?? 0, name, id]);
          for (final dup in colliding) {
            final dupId = (dup['id'] as num?)?.toInt();
            if (dupId != null) {
              await txn.update(
                'item_categories',
                {'name': '$name (مؤرشف $dupId)', 'updated_at': nowIso},
                where: 'id = ?',
                whereArgs: [dupId],
              );
            }
          }

          await txn.insert(
            'item_categories',
            {
              'id': id,
              'workspace_id': wsId,
              'name': name,
              'parent_id': safeParentId,
              'section_id': safeSecId,
              'icon_key': '${c['icon_key'] ?? ''}',
              'color_hex': '${c['color_hex'] ?? ''}',
              'image_path': '${c['image_path'] ?? ''}',
              'deleted_at': '',
              'deleted_by': null,
              'restore_op_id': '${c['restore_op_id'] ?? ''}',
              'created_at': '${c['created_at'] ?? nowIso}'.trim().isEmpty
                  ? nowIso
                  : '${c['created_at']}',
              'updated_at': nowIso,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          restoredCategories++;
          touchedCategoryIds.add(id);
        }

        // 3) استرجاع الأصناف جراحياً دون المساس بالكميات الحالية للأصناف النشطة
        for (final it in itemsList) {
          final id = (it['id'] as num?)?.toInt();
          final name = '${it['name'] ?? ''}'.trim();
          final isDelFlag = (it['is_deleted'] as num?)?.toInt() == 1;
          final delAt = '${it['deleted_at'] ?? ''}'.trim();
          if (id == null ||
              id <= 0 ||
              isKnownAutoSplitItemId(id) ||
              name.isEmpty ||
              isDelFlag ||
              delAt.isNotEmpty) {
            continue;
          }

          final existing = await txn.query(
            'items',
            columns: ['id', 'quantity', 'plu', 'is_deleted', 'deleted_at'],
            where: 'id = ?',
            whereArgs: [id],
            limit: 1,
          );

          final safeCatId =
              await _resolveValidCategoryId(txn, (it['category_id'] as num?)?.toInt());
          final safeSecId =
              await _resolveValidSectionId(txn, (it['section_id'] as num?)?.toInt());

          final backupQty = ((it['quantity'] as num?) ?? 0).toDouble();
          final wasExistingActive = existing.isNotEmpty &&
              ((existing.first['is_deleted'] as num?)?.toInt() ?? 0) == 0 &&
              '${existing.first['deleted_at'] ?? ''}'.trim().isEmpty;
          // إذا كان الصنف قائماً ونشطاً نحافظ على كميته الحالية بعد الفواتير اللاحقة،
          // أما إن كان محذوفاً أو مفقوداً فنستعيد كميته من النسخة.
          final preservedQty = wasExistingActive
              ? ((existing.first['quantity'] as num?) ?? backupQty).toDouble()
              : backupQty;

          final rawPlu = (it['plu'] as num?)?.toInt();
          final existingPlu = existing.isNotEmpty
              ? (existing.first['plu'] as num?)?.toInt()
              : null;
          final safePlu = (rawPlu != null && rawPlu > 0 && rawPlu <= 1000000000)
              ? rawPlu
              : ((existingPlu != null &&
                      existingPlu > 0 &&
                      existingPlu <= 1000000000)
                  ? existingPlu
                  : (id <= 1000000000 ? id : null));

          final row = <String, Object?>{
            'id': id,
            'workspace_id': wsId,
            'name': name,
            'category_id': safeCatId,
            'section_id': safeSecId,
            'plu': safePlu,
            'sku': '${it['sku'] ?? ''}'.trim(),
            'unit': '${it['unit'] ?? 'حبة'}'.trim().isEmpty
                ? 'حبة'
                : '${it['unit']}'.trim(),
            'buy_price': ((it['buy_price'] as num?) ?? 0).toDouble(),
            'sell_price': ((it['sell_price'] as num?) ?? 0).toDouble(),
            'quantity': preservedQty,
            'min_quantity': ((it['min_quantity'] as num?) ?? 0).toDouble(),
            'currency': '${it['currency'] ?? 'YER'}'.trim().isEmpty
                ? 'YER'
                : '${it['currency']}'.trim(),
            'category': '${it['category'] ?? ''}',
            'notes': '${it['notes'] ?? ''}',
            'image': '${it['image'] ?? ''}',
            'archived': (it['archived'] as num?)?.toInt() ?? 0,
            'is_deleted': 0,
            'is_active': 1,
            'exclude_from_shortages':
                (it['exclude_from_shortages'] as num?)?.toInt() ?? 0,
            'deleted_at': '',
            'deleted_by': null,
            'restore_op_id': '${it['restore_op_id'] ?? ''}',
            'created_at': '${it['created_at'] ?? nowIso}'.trim().isEmpty
                ? nowIso
                : '${it['created_at']}',
            'updated_at': nowIso,
          };

          await txn.insert(
            'items',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          restoredItems++;
          touchedItemIds.add(id);
        }

        await _advanceLastPlu(txn, wsId);

        if (syncToGroup) {
          final rec = await repo.newRecorder(txn);
          for (final id in touchedSectionIds) {
            final rows = await txn.query(
              'sections',
              where: 'id = ?',
              whereArgs: [id],
              limit: 1,
            );
            if (rows.isEmpty) continue;
            await rec.record(
              entityType: EntityKind.section,
              entityId: '$id',
              opType: OpKind.update,
              payload: Map<String, Object?>.from(rows.first),
            );
            queuedSyncOps++;
          }
          for (final id in touchedCategoryIds) {
            final rows = await txn.query(
              'item_categories',
              where: 'id = ?',
              whereArgs: [id],
              limit: 1,
            );
            if (rows.isEmpty) continue;
            await rec.record(
              entityType: EntityKind.itemCategory,
              entityId: '$id',
              opType: OpKind.update,
              payload: Map<String, Object?>.from(rows.first),
            );
            queuedSyncOps++;
          }
          for (final id in touchedItemIds) {
            final rows = await txn.query(
              'items',
              where: 'id = ?',
              whereArgs: [id],
              limit: 1,
            );
            if (rows.isEmpty) continue;
            final payload = Map<String, Object?>.from(rows.first)
              ..['id'] = id
              ..['__qty_changed'] = 1;
            await rec.record(
              entityType: EntityKind.item,
              entityId: '$id',
              opType: OpKind.update,
              payload: payload,
            );
            queuedSyncOps++;
          }
        }
      });

      await repo.logActivity(
        'استرجاع كتالوج الأصناف من نسخة احتياطية ($restoredItems صنف، $restoredCategories فئة، $restoredSections قسم) بدون مساس بالفواتير',
        'item',
        '',
      );

      return CatalogRecoveryResult(
        restoredItems: restoredItems,
        revertedQtyMoves: 0,
        resetConflicts: 0,
        restoredSections: restoredSections,
        restoredCategories: restoredCategories,
        queuedSyncOps: queuedSyncOps,
        safetyBackupPath: safetyPath,
      );
    } finally {
      await inspection?.dispose();
    }
  }

  static Future<int?> _resolveValidCategoryId(
    DatabaseExecutor txn,
    int? catId, {
    int? excludeId,
  }) async {
    if (catId == null || catId <= 0 || catId == excludeId) return null;
    final rows = await txn.query(
      'item_categories',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [catId],
      limit: 1,
    );
    return rows.isNotEmpty ? catId : null;
  }

  static Future<int?> _resolveValidSectionId(
    DatabaseExecutor txn,
    int? secId,
  ) async {
    if (secId == null || secId <= 0) return null;
    final rows = await txn.query(
      'sections',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [secId],
      limit: 1,
    );
    return rows.isNotEmpty ? secId : null;
  }

  static Future<void> _advanceLastPlu(DatabaseExecutor txn, String wsId) async {
    try {
      final maxRows = await txn.rawQuery(
        'SELECT COALESCE(MAX(plu), 0) AS mx FROM items WHERE plu IS NOT NULL AND plu <= 1000000000',
      );
      final maxPlu = (maxRows.firstOrNull?['mx'] as num?)?.toInt() ?? 0;
      if (maxPlu <= 0) return;
      final existing = await txn.query(
        'sync_meta',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['last_plu:$wsId'],
        limit: 1,
      );
      final cur = existing.isNotEmpty
          ? (int.tryParse('${existing.first['value'] ?? '0'}') ?? 0)
          : 0;
      if (maxPlu > cur) {
        await txn.insert(
          'sync_meta',
          {'key': 'last_plu:$wsId', 'value': '$maxPlu'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    } catch (_) {}
  }
}
