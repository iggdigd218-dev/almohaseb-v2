// مسجّل العمليات: يُستدعى داخل معاملة الحفظ لإدخال Operation
// وإدراجها في sync_queue atomically مع حفظ الكيان المحلي.
import 'dart:convert';
import 'package:sqflite/sqflite.dart';

import 'operation.dart';
import 'sync_queue.dart';
import 'workspace_service.dart';
import '../../core/cloud_config.dart';
import '../../core/database.dart';

typedef SyncNotifyFn = void Function();

/// الحد الأقصى لحمولة عملية واحدة بعد الترميز JSON.
/// ناقل LAN يرفض الطلبات فوق 8MB (kMaxLanPayloadBytes) — نفرض الحد هنا
/// عند التسجيل حتى لا تدخل الطابور عملية لا يمكن تسليمها أبداً
/// (كانت تعلق pending للأبد وتسد الطابور خلفها).
const int kMaxOperationPayloadBytes = 8 * 1024 * 1024 - 64 * 1024;

class SyncRecorder {
  /// Callback static يُستدعى بعد تسجيل عملية جديدة — لتحفيز push فوري.
  static SyncNotifyFn? onOperationRecorded;

  final DatabaseExecutor db;
  final String deviceId;
  final int? userId;
  String workspaceId;

  SyncRecorder({
    required this.db,
    required this.deviceId,
    required this.workspaceId,
    this.userId,
  });

  static Future<SyncRecorder> forTransaction(
    Transaction txn, {
    required String deviceId,
    int? userId,
    String workspaceId = defaultWorkspaceId,
  }) async {
    return SyncRecorder(
      db: txn,
      deviceId: deviceId,
      userId: userId,
      workspaceId: workspaceId,
    );
  }

  /// تعافٍ ذاتي فوري (Auto-Heal): ينشئ جداول المزامنة الأساسية في حال
  /// واجَه الحفظ قاعدة ناقصة الجداول، دون إفشال عملية المستخدم.
  ///
  /// (تنظيف المخطط) لا نُكرّر جمل `CREATE TABLE` هنا: المصدر الوحيد هو
  /// `AppDatabase.ensureSyncTablesForExecutor` — تُرقّي الأعمدة القديمة
  /// (`is_synced`) أيضًا، فأي تعديل مستقبلي في المخطط يقع في مكان واحد.
  Future<void> _autoHealMissingSyncTables() async {
    await AppDatabase.ensureSyncTablesForExecutor(db);
  }

  static bool _isMissingTableError(Object e) =>
      '$e'.toLowerCase().contains('no such table');

  /// آخر version معروف للكيان (للبدء من 1 إن لم يوجد).
  Future<int> nextVersion(EntityKind entity, String entityId) async {
    try {
      final r = await db.rawQuery(
        'SELECT MAX(version) AS v FROM operations WHERE entity_type = ? AND entity_id = ?',
        [entity.name, entityId],
      );
      final cur = (r.first['v'] as int?) ?? 0;
      return cur + 1;
    } on DatabaseException catch (e) {
      if (_isMissingTableError(e)) {
        await _autoHealMissingSyncTables();
        final r = await db.rawQuery(
          'SELECT MAX(version) AS v FROM operations WHERE entity_type = ? AND entity_id = ?',
          [entity.name, entityId],
        );
        final cur = (r.isNotEmpty ? r.first['v'] as int? : null) ?? 0;
        return cur + 1;
      }
      rethrow;
    }
  }

  /// يسجّل عملية في جدول operations + صفوف في sync_queue.
  /// يُستدعى داخل Transaction.
  Future<String> record({
    required EntityKind entityType,
    required String entityId,
    required OpKind opType,
    required Map<String, Object?> payload,
    String parentOpId = '',
    int? version,
    List<String> extraTargets = const [], // مثلاً device:<id>
  }) async {
    final id = uuid();
    final now = DateTime.now();
    final v = version ?? await nextVersion(entityType, entityId);
    // فحص صارم للحجم الخام قبل الإدراج: حمولة تتجاوز حد ناقل HTTP (8MB) لن
    // تُسلَّم أبداً — نرفضها هنا فتفشل معاملة الحفظ كلها (ACID) بدل
    // عملية عالقة pending للأبد تسد الطابور.
    final rawPayloadStr = jsonEncode(payload);
    if (rawPayloadStr.length > kMaxOperationPayloadBytes) {
      throw StateError(
        'حجم البيانات المرفقة يتجاوز الحد المسموح للمزامنة '
        '(${(kMaxOperationPayloadBytes / (1024 * 1024)).toStringAsFixed(1)} MB) '
        '— قلّل حجم المرفق وأعد المحاولة.',
      );
    }
    final sanitizedPayload = sanitizeOperationPayload(
      payload,
      entityType: entityType,
      entityId: entityId,
      preserveChatAttachment: entityType == EntityKind.message,
    );
    final op = SyncOperation(
      id: id,
      deviceId: deviceId,
      workspaceId: workspaceId,
      userId: userId,
      entityType: entityType,
      entityId: entityId,
      opType: opType,
      version: v,
      parentOpId: parentOpId,
      payload: sanitizedPayload,
      deviceTime: now.toIso8601String(),
      timestamp: now.toIso8601String(),
      isSynced: 0,
    );
    final opMap = op.toMap();
    final payloadStr = opMap['payload'] as String? ?? '';
    if (payloadStr.length > kMaxOperationPayloadBytes) {
      throw StateError(
        'حجم البيانات المرفقة يتجاوز الحد المسموح للمزامنة '
        '(${(kMaxOperationPayloadBytes / (1024 * 1024)).toStringAsFixed(1)} MB) '
        '— قلّل حجم المرفق وأعد المحاولة.',
      );
    }
    try {
      await db.insert('operations', opMap);
    } on DatabaseException catch (e) {
      if (_isMissingTableError(e)) {
        await _autoHealMissingSyncTables();
        await db.insert('operations', opMap);
      } else if ('$e'.contains('is_synced')) {
        await db.insert('operations', op.toMap(includeIsSynced: false));
      } else {
        rethrow;
      }
    }

    final qnow = now.toIso8601String();
    // لا نضيف هدف Cloud إلا إذا كان خادم سحابي مهيأ فعلاً — إضافته دائماً
    // كانت تترك صفوفاً «بانتظار الإرسال» للأبد (لا ناقل يلتقطها) فتظهر
    // للمستخدم كمزامنات عالقة وتزاحم الطابور.
    List<Map<String, Object?>> st;
    try {
      st = await db.query('settings',
          columns: ['key', 'value'],
          where: 'key IN (?, ?, ?)',
          whereArgs: ['cloudBackendUrl', 'cloudAutoSync', 'account.type']);
    } on DatabaseException catch (e) {
      if (_isMissingTableError(e)) {
        await _autoHealMissingSyncTables();
        st = await db.query('settings',
            columns: ['key', 'value'],
            where: 'key IN (?, ?, ?)',
            whereArgs: ['cloudBackendUrl', 'cloudAutoSync', 'account.type']);
      } else {
        rethrow;
      }
    }
    final map = {for (final r in st) r['key'] as String: r['value'] as String?};
    final cloudOn =
        effectiveBackendUrl(map['cloudBackendUrl']).isNotEmpty &&
            kCloudAutoSyncAlways; // مثبتة دائماً (المعمارية الصامتة).
    // (دفعة 58) «السحابة حصرياً»: Firebase RTDB هو الناقل الوحيد —
    // اجتُثت طبقة LAN نهائياً، لا هدف lan في الطابور بعد اليوم.
    // (3.70) الحساب الفردي: محلي بالكامل — لا تُستدعى sync_queue إطلاقاً
    // (لا أهداف، لا شبكة). العمليات تبقى في سجل operations المحلي فقط.
    final individual = (map['account.type'] ?? '') == 'individual';
    final targets = individual
        ? <String>{}
        : <String>{
            if (cloudOn) SyncTarget.cloud,
            ...extraTargets,
          };
    for (final t in targets) {
      final qRow = {
        'operation_id': id,
        'status': SyncStatus.pending.name,
        'target': t,
        'attempts': 0,
        'last_error': '',
        'next_try_at': '',
        'created_at': qnow,
        'updated_at': qnow,
      };
      try {
        await db.insert('sync_queue', qRow,
            conflictAlgorithm: ConflictAlgorithm.ignore);
      } on DatabaseException catch (e) {
        if (_isMissingTableError(e)) {
          await _autoHealMissingSyncTables();
          await db.insert('sync_queue', qRow,
              conflictAlgorithm: ConflictAlgorithm.ignore);
        } else {
          rethrow;
        }
      }
    }
    // إشعار بمحاولة push فورية بعد الانتهاء من المعاملة (جدولة خارج الـ txn).
    try {
      onOperationRecorded?.call();
    } catch (_) {}
    return id;
  }
}
