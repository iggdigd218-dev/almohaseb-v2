import 'dart:convert';

/// نموذج تعارض الأصناف والباركود الناتج عن الإدخال أثناء انقطاع الإنترنت (Offline).
class OfflineItemConflict {
  /// مفتاح الإعداد المخزّن في جدول settings (مثل: `item_conflict:100_101`).
  final String key;

  /// نوع التعارض: `'id'` | `'sku'` | `'id_and_sku'`.
  final String conflictType;

  /// رقم الصنف الأصلي المتعارض قبل الفصل التلقائي (إن وُجد).
  final int? originalCollidingId;

  /// الباركود المشترك بين الصنفين (إن وُجد).
  final String sharedSku;

  /// بيانات الصنف الأول.
  final int item1Id;
  final String item1Name;
  final String item1Creator;

  /// بيانات الصنف الثاني (الذي أُعيد ترقيمه أو اشترك في الباركود).
  final int item2Id;
  final String item2Name;
  final String item2Creator;

  /// حالة التعارض: `'pending'` | `'resolved'`.
  final String status;

  /// طريقة المعالجة المعتمدة: `''` | `'barcode_changed'` | `'merged'` | `'keep_separate'`.
  final String resolution;

  final String createdAt;
  final String resolvedAt;

  const OfflineItemConflict({
    required this.key,
    required this.conflictType,
    this.originalCollidingId,
    this.sharedSku = '',
    required this.item1Id,
    required this.item1Name,
    required this.item1Creator,
    required this.item2Id,
    required this.item2Name,
    required this.item2Creator,
    this.status = 'pending',
    this.resolution = '',
    required this.createdAt,
    this.resolvedAt = '',
  });

  bool get isPending => status == 'pending';
  bool get isResolved => status == 'resolved';
  bool get hasIdConflict =>
      conflictType == 'id' || conflictType == 'id_and_sku';
  bool get hasSkuConflict =>
      conflictType == 'sku' || conflictType == 'id_and_sku';

  String get conflictTypeLabel {
    final orig = originalCollidingId ?? item1Id;
    return switch (conflictType) {
      'id_and_sku' =>
        'تعارض رقم صنف (#$orig تم فصله تلقائياً إلى #$item2Id) + اشتراك في نفس الباركود ($sharedSku)',
      'id' => 'تعارض رقم صنف (#$orig تم فصله تلقائياً إلى #$item2Id)',
      'sku' => 'اشتراك في نفس الباركود ($sharedSku)',
      _ => 'تعارض بيانات صنف (أوفلاين)',
    };
  }

  String get notificationTitle => switch (conflictType) {
        'id_and_sku' => '⚠️ تعارض رقم صنف وباركود مشترك (أوفلاين)',
        'id' => '⚠️ تعارض رقم صنف أوفلاين (تم الفصل تلقائياً)',
        'sku' => '⚠️ اشتراك صنفين في نفس الباركود (أوفلاين)',
        _ => '⚠️ تعارض أصناف بعد المزامنة',
      };

  String get notificationBody =>
      '• الصنف الأول: «$item1Name» (المدخل: $item1Creator)\n'
      '• الصنف الثاني: «$item2Name» (المدخل: $item2Creator)\n'
      '• نوع التعارض: $conflictTypeLabel';

  OfflineItemConflict copyWith({
    String? key,
    String? conflictType,
    int? originalCollidingId,
    String? sharedSku,
    int? item1Id,
    String? item1Name,
    String? item1Creator,
    int? item2Id,
    String? item2Name,
    String? item2Creator,
    String? status,
    String? resolution,
    String? createdAt,
    String? resolvedAt,
  }) =>
      OfflineItemConflict(
        key: key ?? this.key,
        conflictType: conflictType ?? this.conflictType,
        originalCollidingId: originalCollidingId ?? this.originalCollidingId,
        sharedSku: sharedSku ?? this.sharedSku,
        item1Id: item1Id ?? this.item1Id,
        item1Name: item1Name ?? this.item1Name,
        item1Creator: item1Creator ?? this.item1Creator,
        item2Id: item2Id ?? this.item2Id,
        item2Name: item2Name ?? this.item2Name,
        item2Creator: item2Creator ?? this.item2Creator,
        status: status ?? this.status,
        resolution: resolution ?? this.resolution,
        createdAt: createdAt ?? this.createdAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
      );

  Map<String, Object?> toMap() => {
        'key': key,
        'conflict_type': conflictType,
        'original_colliding_id': originalCollidingId,
        'shared_sku': sharedSku,
        'item1_id': item1Id,
        'item1_name': item1Name,
        'item1_creator': item1Creator,
        'item2_id': item2Id,
        'item2_name': item2Name,
        'item2_creator': item2Creator,
        'status': status,
        'resolution': resolution,
        'created_at': createdAt,
        'resolved_at': resolvedAt,
      };

  String toJson() => jsonEncode(toMap());

  factory OfflineItemConflict.fromMap(Map<String, Object?> m) {
    final i1 = (m['item1_id'] as num?)?.toInt() ??
        int.tryParse('${m['item1_id'] ?? ''}') ??
        0;
    final i2 = (m['item2_id'] as num?)?.toInt() ??
        int.tryParse('${m['item2_id'] ?? ''}') ??
        0;
    final orig = (m['original_colliding_id'] as num?)?.toInt() ??
        int.tryParse('${m['original_colliding_id'] ?? ''}');
    final rawKey = '${m['key'] ?? ''}'.trim();
    return OfflineItemConflict(
      key: rawKey.isNotEmpty ? rawKey : 'item_conflict:${i1}_$i2',
      conflictType: '${m['conflict_type'] ?? 'sku'}'.trim(),
      originalCollidingId: orig,
      sharedSku: '${m['shared_sku'] ?? ''}'.trim(),
      item1Id: i1,
      item1Name: '${m['item1_name'] ?? ''}'.trim(),
      item1Creator: '${m['item1_creator'] ?? 'جهاز 1'}'.trim(),
      item2Id: i2,
      item2Name: '${m['item2_name'] ?? ''}'.trim(),
      item2Creator: '${m['item2_creator'] ?? 'جهاز 2'}'.trim(),
      status: '${m['status'] ?? 'pending'}'.trim(),
      resolution: '${m['resolution'] ?? ''}'.trim(),
      createdAt: '${m['created_at'] ?? ''}'.trim(),
      resolvedAt: '${m['resolved_at'] ?? ''}'.trim(),
    );
  }

  static OfflineItemConflict? tryParseJson(String raw, {String? fallbackKey}) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final map = Map<String, Object?>.from(decoded);
        if (fallbackKey != null &&
            (map['key'] == null || '${map['key']}'.trim().isEmpty)) {
          map['key'] = fallbackKey;
        }
        return OfflineItemConflict.fromMap(map);
      }
    } catch (_) {}
    return null;
  }
}

/// خطاف إشعارات تعارض الأصناف الفورية لعرض تنبيه Banner واضح لحظة اكتشاف التعارض.
class ItemConflictHooks {
  static void Function(OfflineItemConflict conflict)? onConflictDetected;

  static void notifyConflict(OfflineItemConflict conflict) {
    try {
      onConflictDetected?.call(conflict);
    } catch (_) {}
  }
}
