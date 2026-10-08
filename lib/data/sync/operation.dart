// نموذج عملية المزامنة (Operation Log Entry).
// كل عملية إنشاء/تعديل/حذف/استعادة تُسجل في هذا الكائن أولاً محليًا،
// ثم تُرفع إلى السحابة أو الأجهزة الأخرى عبر SyncEngine.
import 'dart:convert';

/// أنواع العمليات المدعومة.
enum OpKind { create, update, delete_, restore, settings }

/// الكيانات التي يمكن تتبعها.
enum EntityKind {
  account,
  tx,
  item,
  itemCategory,
  stockMove,
  voucher,
  user,
  currency,
  setting,
  category, // تصنيفات الحسابات (جدول categories)
  conversation, // محادثات الدردشة
  message, // رسائل الدردشة (دردشة المجموعة بين الأجهزة)
  unknown, // نوع من إصدار أحدث — يُتجاهل بأمان ولا يُكتب في أي جدول
  userPermission, // (3.70) صفوف الصلاحيات المحلية user_permissions
  section; // (2026-09-22) أقسام المتجر (sections)

  /// ══ (2026-09-22) أمان الإصدارات المختلطة ══
  /// كان أي نوع غير معروف يسقط على `tx` فيُدرج صف القسم/الكيان الجديد في
  /// جدول transactions (بيانات تالفة). صار يعود `unknown`، والتطبيق
  /// يتجاهله صراحةً (apply_remote) فلا يُكتب شيء في جدول خاطئ.
  static EntityKind from(String s) => EntityKind.values.firstWhere(
        (e) => e.name == s,
        orElse: () => EntityKind.unknown,
      );
}

/// حالات المزامنة لصف في sync_queue.
enum SyncStatus { pending, syncing, synced, failed }

extension SyncStatusName on SyncStatus {
  String get s => name;
  static SyncStatus from(String s) => SyncStatus.values.firstWhere(
        (e) => e.name == s,
        orElse: () => SyncStatus.pending,
      );
}

/// اتجاه/هدف المزامنة (سحابة أو جهاز محدد).
class SyncTarget {
  static const cloud = 'cloud';
  static String device(String deviceId) => 'device:$deviceId';
  static bool isDevice(String t) => t.startsWith('device:');
  static String deviceIdOf(String t) => t.replaceFirst('device:', '');
}

/// حظر تضمين الوسائط والبيانات الثقيلة (صور الفواتير، سلاسل Base64، وسائط الدردشة)
/// داخل عقد operations في Firebase RTDB، والاكتفاء بالبيانات المحاسبية النصية الخفيفة.
Map<String, Object?> sanitizeOperationPayload(
  Map<String, Object?> payload, {
  EntityKind? entityType,
  String? entityId,
}) {
  if (payload.isEmpty) return const {};
  const forbiddenMediaKeys = <String>{
    'file_b64',
    'image_b64',
    'photo_b64',
    'attachment_b64',
    'media_b64',
    'audio_b64',
    'video_b64',
    'receipt_b64',
  };
  const mediaPathOrBlobKeys = <String>{
    'image',
    'attachment',
    'image_path',
    'photo_url',
    'receipt_image',
  };
  final cleaned = <String, Object?>{};
  final hadFileB64 =
      payload['file_b64'] is String && (payload['file_b64'] as String).isNotEmpty;

  for (final entry in payload.entries) {
    final k = entry.key;
    final v = entry.value;
    if (forbiddenMediaKeys.contains(k)) {
      continue;
    }
    if (mediaPathOrBlobKeys.contains(k)) {
      // منع إدراج صور الفواتير أو المرفقات أو سلاسل Base64 داخل عقد operations
      continue;
    }
    if (v is String && _looksLikeBase64OrDataUri(v, key: k, entityType: entityType, entityId: entityId)) {
      continue;
    }
    cleaned[k] = v;
  }
  if (hadFileB64) {
    cleaned['file_pruned'] = 1;
  }
  return cleaned;
}

bool _looksLikeBase64OrDataUri(
  String value, {
  required String key,
  EntityKind? entityType,
  String? entityId,
}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith('data:') && trimmed.contains(';base64,')) {
    return true;
  }
  // استثناء إعداد أيقونة المنشأة المصغرة في اختبارات الإعدادات المحليّة القصيرة
  if (entityType == EntityKind.setting && entityId == 'org.icon.b64' && trimmed.length <= 512) {
    return false;
  }
  if (key.endsWith('_b64') || key.endsWith('Base64')) {
    return true;
  }
  // سلاسل Base64 الطويلة غير النصية (> 1024 حرفاً متصلاً بلا مسافات)
  if (trimmed.length > 1024 && !trimmed.contains(' ') && RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(trimmed)) {
    return true;
  }
  return false;
}

/// عملية مزامنة واحدة (سجل غير قابل للتعديل بعد الإنشاء).
class SyncOperation {
  /// UUID عالمي فريد. أساس Idempotency: نفس الـ id لا يُطبّق مرتين.
  final String id;
  final String deviceId;
  final String workspaceId;
  final int? userId; // users.id المحلي (اختياري في وضع non-login).
  final EntityKind entityType;
  final String entityId; // المعرّف المحلي للكيان (int أو نص).
  final OpKind opType;
  final int version; // نسخة الكيان بعد تطبيق هذه العملية.
  final String parentOpId; // لعملية restore: عملية delete الأصلية.
  final Map<String, Object?> payload; // Snapshot كامل للكيان بعد العملية.
  final String deviceTime; // ISO 8601 وقت الجهاز.
  final String? serverTime; // وقت السيرفر عند الـ sync (يملأه الـ transport أو ServerValue.TIMESTAMP).
  final String timestamp; // وقت إنشاء السجل محليًا.
  final int isSynced; // 0 = غير متزامنة، 1 = متزامنة ومؤكدة مع السيرفر.

  const SyncOperation({
    required this.id,
    required this.deviceId,
    required this.workspaceId,
    required this.userId,
    required this.entityType,
    required this.entityId,
    required this.opType,
    required this.version,
    required this.parentOpId,
    required this.payload,
    required this.deviceTime,
    required this.timestamp,
    this.serverTime,
    this.isSynced = 0,
  });

  /// وقت الخادم بالملي ثانية (من server_time الرقمي أو النصي) للاعتماد الحصري عليه
  /// في مؤشر السحب (last_synced_cursor) وفي حسم التعارضات (Conflict Resolution).
  int get serverTimeMs {
    final st = serverTime;
    if (st != null && st.isNotEmpty) {
      final asInt = int.tryParse(st);
      if (asInt != null && asInt > 0) return asInt;
      final asNum = num.tryParse(st);
      if (asNum != null && asNum > 0) return asNum.toInt();
      final asDate = DateTime.tryParse(st)?.millisecondsSinceEpoch;
      if (asDate != null && asDate > 0) return asDate;
    }
    return 0;
  }

  Map<String, Object?> toMap({bool includeIsSynced = true}) => {
        'id': id,
        'device_id': deviceId,
        'workspace_id': workspaceId,
        'user_id': userId,
        'entity_type': entityType.name,
        'entity_id': entityId,
        'op_type': opType.name,
        'version': version,
        'parent_op_id': parentOpId,
        'payload': jsonEncode(payload),
        'device_time': deviceTime,
        'server_time': serverTime,
        'timestamp': timestamp,
        'synced': isSynced,
        if (includeIsSynced) 'is_synced': isSynced,
      };

  static String? _parseServerTime(Object? primary, Object? fallbackTs) {
    for (final raw in [primary, fallbackTs]) {
      if (raw == null) continue;
      if (raw is int && raw > 0) return '$raw';
      if (raw is num && raw > 0) return '${raw.toInt()}';
      if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    }
    return null;
  }

  static int _parseSyncedFlag(Object? isSyncedVal, Object? syncedVal) {
    for (final v in [isSyncedVal, syncedVal]) {
      if (v is int) return v != 0 ? 1 : 0;
      if (v is num) return v.toInt() != 0 ? 1 : 0;
      if (v is bool) return v ? 1 : 0;
      if (v is String) {
        if (v == '1' || v.toLowerCase() == 'true') return 1;
        if (v == '0' || v.toLowerCase() == 'false') return 0;
      }
    }
    return 0;
  }

  static SyncOperation fromMap(Map<String, Object?> m) => SyncOperation(
        id: m['id'] as String,
        deviceId: (m['device_id'] as String?) ?? '',
        workspaceId: (m['workspace_id'] as String?) ?? 'default',
        userId: m['user_id'] as int?,
        entityType: EntityKind.from((m['entity_type'] as String?) ?? 'tx'),
        entityId: (m['entity_id'] as String?) ?? '',
        opType: _opFrom((m['op_type'] as String?) ?? 'create'),
        version: (m['version'] as int?) ?? 1,
        parentOpId: (m['parent_op_id'] as String?) ?? '',
        payload: _decodeJson(m['payload']),
        deviceTime: (m['device_time'] as String?) ?? '',
        serverTime: _parseServerTime(m['server_time'], m['server_ts']),
        timestamp: (m['timestamp'] as String?) ?? '',
        isSynced: _parseSyncedFlag(m['is_synced'], m['synced']),
      );

  String toJson() => jsonEncode(toMap());
  static SyncOperation fromJson(String s) =>
      fromMap(jsonDecode(s) as Map<String, Object?>);

  @override
  bool operator ==(Object other) => other is SyncOperation && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

OpKind _opFrom(String s) {
  switch (s) {
    case 'create':
      return OpKind.create;
    case 'update':
      return OpKind.update;
    case 'delete_':
    case 'delete':
      return OpKind.delete_;
    case 'restore':
      return OpKind.restore;
    case 'settings':
      return OpKind.settings;
  }
  return OpKind.create;
}

Map<String, Object?> _decodeJson(Object? v) {
  if (v == null) return {};
  if (v is String) {
    try {
      final d = jsonDecode(v);
      return d is Map<String, Object?> ? d : {'_raw': d};
    } catch (_) {
      return {};
    }
  }
  if (v is Map) return Map<String, Object?>.from(v);
  return {};
}
