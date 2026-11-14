import 'accounting.dart';

DateTime? _epochToDateTime(num value) {
  if (!value.isFinite) return null;
  final n = value.round();
  if (n <= 0) return null;
  if (n >= 100000000000000) {
    return DateTime.fromMicrosecondsSinceEpoch(n);
  }
  if (n >= 100000000000) {
    return DateTime.fromMillisecondsSinceEpoch(n);
  }
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}

String _normalizeAsciiDigits(String input) {
  const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
  const easternIndic = '۰۱۲۳۴۵۶۷۸۹';
  final buf = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    final ai = arabicIndic.indexOf(ch);
    if (ai >= 0) {
      buf.write(ai);
      continue;
    }
    final ei = easternIndic.indexOf(ch);
    if (ei >= 0) {
      buf.write(ei);
      continue;
    }
    buf.write(ch);
  }
  return buf.toString();
}

/// تحليل آمن للتواريخ يعيد `null` عند القيم الفارغة أو غير الصالحة دون رمي [FormatException].
/// يدعم صيغ ISO-8601، وأرقام Epoch (ثوانٍ/ميلي ثانية/ميكرو ثانية)، والتواريخ ذات الفواصل غير القياسية.
DateTime? safeParseNullableDateTime(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  if (raw is num) return _epochToDateTime(raw);
  try {
    var s = _normalizeAsciiDigits('$raw').trim();
    if (s.isEmpty) return null;
    final lower = s.toLowerCase();
    if (lower == 'null' ||
        lower == 'undefined' ||
        lower == 'nan' ||
        lower == 'none' ||
        lower == '-') {
      return null;
    }

    final asNum = num.tryParse(s);
    if (asNum != null && asNum >= 100000000) {
      return _epochToDateTime(asNum);
    }

    final direct = DateTime.tryParse(s);
    if (direct != null) return direct;

    if (asNum != null) return _epochToDateTime(asNum);

    s = s.replaceFirstMapped(
      RegExp(r'(\d{1,2}:\d{1,2}:\d{1,2}),(\d+)'),
      (m) => '${m[1]}.${m[2]}',
    );
    s = s.replaceFirst(RegExp(r'\s+(?:UTC|GMT)$', caseSensitive: false), 'Z');
    final normalizedTry = DateTime.tryParse(s);
    if (normalizedTry != null) return normalizedTry;

    // صيغة YYYY/MM/DD أو YYYY.MM.DD أو YYYY-M-D مع وقت اختياري
    final ymd = RegExp(
      r'^(\d{4})[\/\-\.\s](\d{1,2})[\/\-\.\s](\d{1,2})'
      r'(?:[T\s_]+(\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.(\d+))?)?'
      r'(?:\s*(Z|[+\-]\d{2}:?\d{2}|[+\-]\d{2}))?)?$',
      caseSensitive: false,
    ).firstMatch(s);
    if (ymd != null) {
      final year = int.parse(ymd.group(1)!);
      final month = int.parse(ymd.group(2)!);
      final day = int.parse(ymd.group(3)!);
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        final hh = int.parse(ymd.group(4) ?? '0').toString().padLeft(2, '0');
        final mm = int.parse(ymd.group(5) ?? '0').toString().padLeft(2, '0');
        final ss = int.parse(ymd.group(6) ?? '0').toString().padLeft(2, '0');
        final frac = ymd.group(7) != null ? '.${ymd.group(7)}' : '';
        var tz = (ymd.group(8) ?? '').toUpperCase();
        if (RegExp(r'^[+\-]\d{2}$').hasMatch(tz)) tz = '$tz:00';
        final iso =
            '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}T$hh:$mm:$ss$frac$tz';
        final dt = DateTime.tryParse(iso);
        if (dt != null) return dt;
      }
    }

    // صيغة DD/MM/YYYY أو DD-MM-YYYY (أو MM/DD/YYYY عند تجاوز اليوم 12)
    final dmy = RegExp(
      r'^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{4})'
      r'(?:[T\s_]+(\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.(\d+))?)?'
      r'(?:\s*(Z|[+\-]\d{2}:?\d{2}|[+\-]\d{2}))?)?$',
      caseSensitive: false,
    ).firstMatch(s);
    if (dmy != null) {
      final p1 = int.parse(dmy.group(1)!);
      final p2 = int.parse(dmy.group(2)!);
      final year = int.parse(dmy.group(3)!);
      final int day;
      final int month;
      if (p1 <= 12 && p2 > 12) {
        month = p1;
        day = p2;
      } else {
        day = p1;
        month = p2;
      }
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        final hh = int.parse(dmy.group(4) ?? '0').toString().padLeft(2, '0');
        final mm = int.parse(dmy.group(5) ?? '0').toString().padLeft(2, '0');
        final ss = int.parse(dmy.group(6) ?? '0').toString().padLeft(2, '0');
        final frac = dmy.group(7) != null ? '.${dmy.group(7)}' : '';
        var tz = (dmy.group(8) ?? '').toUpperCase();
        if (RegExp(r'^[+\-]\d{2}$').hasMatch(tz)) tz = '$tz:00';
        final iso =
            '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}T$hh:$mm:$ss$frac$tz';
        final dt = DateTime.tryParse(iso);
        if (dt != null) return dt;
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// تحليل آمن للتواريخ مع قيمة احتياطية مضمونة دون رمي أي استثناء.
DateTime safeParseDateTime(
  Object? raw, {
  Object? fallbackRaw,
  DateTime? fallback,
}) {
  return safeParseNullableDateTime(raw) ??
      (fallbackRaw != null ? safeParseNullableDateTime(fallbackRaw) : null) ??
      fallback ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

/// حساب: عميل أو مورد أو حساب عام.
class Account {
  final int? id;
  final String name;
  final AccountKind kind;

  /// موجب = مستحق لنا (عليه)، سالب = مستحق منا (له).
  final double openingBalance;
  final double balance;
  final String currency;
  final String phone;
  final String whatsapp;
  final String address;
  final String notes;
  final String category;
  final double? creditLimit;
  final List<String> tags;
  final bool archived;
  final String image;

  /// قناة إشعار السند: 'whatsapp' / 'sms' / 'none'.
  final String notifyChannel;

  final DateTime createdAt;
  final DateTime updatedAt;

  const Account({
    this.id,
    required this.name,
    this.kind = AccountKind.customer,
    this.openingBalance = 0,
    this.balance = 0,
    this.currency = 'YER',
    this.phone = '',
    this.whatsapp = '',
    this.address = '',
    this.notes = '',
    this.category = '',
    this.creditLimit,
    this.tags = const [],
    this.archived = false,
    this.image = '',
    this.notifyChannel = 'whatsapp',
    required this.createdAt,
    required this.updatedAt,
  });

  /// الرقم المستخدم للتواصل: واتساب إن وُجد وإلا الهاتف.
  String get contactNumber {
    // (دفعة التدقيق) كل قنوات الواتساب (القديمة 'whatsapp' وauto_*) تعيد
    // رقم الواتساب مع سقوط احتياطي للهاتف، وكل قنوات الرسائل النصية
    // (sms وauto_sms) تعيد رقم الهاتف — كانت القيم auto_* تسقط في الفراغ.
    final ch = notifyChannel;
    if (ch == 'whatsapp' ||
        ch == 'auto_whatsapp' ||
        ch == 'auto_w4b' ||
        ch == 'auto_system') {
      final wa = whatsapp.trim();
      return wa.isNotEmpty ? wa : phone.trim();
    }
    if (ch == 'sms' || ch == 'auto_sms') {
      return phone.trim();
    }
    return '';
  }

  Account copyWith({
    int? id,
    String? name,
    AccountKind? kind,
    double? openingBalance,
    double? balance,
    String? currency,
    String? phone,
    String? whatsapp,
    String? address,
    String? notes,
    String? category,
    double? creditLimit,
    bool clearCreditLimit = false,
    List<String>? tags,
    bool? archived,
    String? image,
    String? notifyChannel,
  }) =>
      Account(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        openingBalance: openingBalance ?? this.openingBalance,
        balance: balance ?? this.balance,
        currency: currency ?? this.currency,
        phone: phone ?? this.phone,
        whatsapp: whatsapp ?? this.whatsapp,
        address: address ?? this.address,
        notes: notes ?? this.notes,
        category: category ?? this.category,
        creditLimit:
            clearCreditLimit ? null : (creditLimit ?? this.creditLimit),
        tags: tags ?? this.tags,
        archived: archived ?? this.archived,
        image: image ?? this.image,
        notifyChannel: notifyChannel ?? this.notifyChannel,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'kind': kind.code,
        'opening_balance': openingBalance,
        'currency': currency,
        'phone': phone,
        'whatsapp': whatsapp,
        'address': address,
        'notes': notes,
        'category': category,
        'credit_limit': creditLimit,
        'tags': tags.join(','),
        'archived': archived ? 1 : 0,
        'image': image,
        'notify_channel': notifyChannel,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Account.fromMap(Map<String, Object?> m) {
    final raw = (m['tags'] ?? '') as String;
    final ob = ((m['opening_balance'] ?? 0) as num).toDouble();
    final bal = ((m['balance'] ?? ob) as num).toDouble();
    return Account(
      id: m['id'] as int?,
      name: (m['name'] ?? '') as String,
      kind: AccountKind.fromCode((m['kind'] ?? 'customer') as String),
      openingBalance: ob,
      balance: bal,
      currency: (m['currency'] ?? 'YER') as String,
      phone: (m['phone'] ?? '') as String,
      whatsapp: (m['whatsapp'] ?? '') as String,
      address: (m['address'] ?? '') as String,
      notes: (m['notes'] ?? '') as String,
      category: (m['category'] ?? '') as String,
      creditLimit: (m['credit_limit'] as num?)?.toDouble(),
      tags: raw.isEmpty
          ? const []
          : raw
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
      archived: ((m['archived'] ?? 0) as int) == 1,
      image: (m['image'] ?? '') as String,
      notifyChannel: (m['notify_channel'] ?? 'whatsapp') as String,
      createdAt: safeParseDateTime(m['created_at'], fallbackRaw: m['updated_at']),
      updatedAt: safeParseDateTime(m['updated_at'], fallbackRaw: m['created_at']),
    );
  }
}

/// عملية مالية.
class Tx {
  final int? id;
  final int? accountId;
  final AccountKind accountKind;
  final OpType type;
  final double amount;
  final String currency;

  /// علامة التسوية: '+' أو '-'. تُستخدم لنوع settle فقط.
  final String sign;
  final int? fromId;
  final int? toId;
  final double rate;
  final String description;
  final String reference;
  final String notes;
  final String category;
  final String attachment;

  /// تجزئة SHA-256 لملف المرفق/الصورة — تسمح للأجهزة الأخرى بجلب الملف
  /// عبر LAN عند الطلب (GET /attachments/:hash) بدل تضمينه في المزامنة.
  final String attachmentHash;

  /// مسار صورة الإيصال المولّدة أو المختارة لهذه العملية (واحدة لكل عملية).
  final String image;
  final String status;

  /// حالة المزامنة المستقلة عن حالة العملية:
  ///  - 'synced': تمت المزامنة بنجاح.
  ///  - 'pending': بانتظار المزامنة.
  ///  - 'syncing': جاري المزامنة.
  ///  - 'failed': فشلت المزامنة.
  ///  - 'local': محلي فقط (جهاز مستقل / غير مُرسل بعد).
  final String syncState;
  final int? createdByUserId;
  final String cashierName;

  /// معرّف الفاتورة الأصلية في حال كانت العملية مرتجع مبيعات (أضيف في v29).
  final String? originalTxId;
  final DateTime date;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Tx({
    this.id,
    this.accountId,
    this.accountKind = AccountKind.customer,
    required this.type,
    required this.amount,
    this.currency = 'YER',
    this.sign = '',
    this.fromId,
    this.toId,
    this.rate = 1,
    this.description = '',
    this.reference = '',
    this.notes = '',
    this.category = '',
    this.attachment = '',
    this.attachmentHash = '',
    this.image = '',
    this.status = 'done',
    this.syncState = 'synced',
    this.createdByUserId,
    this.cashierName = '',
    this.originalTxId,
    required this.date,
    required this.createdAt,
    required this.updatedAt,
  });

  /// أثر هذه العملية على رصيد الحساب [accId]، أو null إن لم تمسّه.
  ///
  /// منقول حرفيًا من `txEffect` في نسخة الويب.
  double? effectOn(int accId) {
    if (type == OpType.transfer) {
      if (fromId == accId) return -amount;
      if (toId == accId) return amount * rate;
      return null;
    }
    if (accountId != accId) return null;
    var eff = opEffect(type, accountKind);
    if (type == OpType.settle) {
      eff = (sign == '+' || sign == '1') ? 1 : -1;
    }
    return eff * amount;
  }

  Tx copyWith({
    int? id,
    int? accountId,
    AccountKind? accountKind,
    OpType? type,
    double? amount,
    String? currency,
    String? sign,
    int? fromId,
    int? toId,
    double? rate,
    String? description,
    String? reference,
    String? notes,
    String? category,
    String? attachment,
    String? attachmentHash,
    String? image,
    String? status,
    String? syncState,
    int? createdByUserId,
    String? cashierName,
    String? originalTxId,
    DateTime? date,
    bool clearAccountId = false,
    bool clearFromId = false,
    bool clearToId = false,
    bool clearOriginalTxId = false,
  }) =>
      Tx(
        id: id ?? this.id,
        accountId: clearAccountId ? null : (accountId ?? this.accountId),
        accountKind: accountKind ?? this.accountKind,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        currency: currency ?? this.currency,
        sign: sign ?? this.sign,
        fromId: clearFromId ? null : (fromId ?? this.fromId),
        toId: clearToId ? null : (toId ?? this.toId),
        rate: rate ?? this.rate,
        description: description ?? this.description,
        reference: reference ?? this.reference,
        notes: notes ?? this.notes,
        category: category ?? this.category,
        attachment: attachment ?? this.attachment,
        attachmentHash: attachmentHash ?? this.attachmentHash,
        image: image ?? this.image,
        status: status ?? this.status,
        syncState: syncState ?? this.syncState,
        createdByUserId: createdByUserId ?? this.createdByUserId,
        cashierName: cashierName ?? this.cashierName,
        originalTxId:
            clearOriginalTxId ? null : (originalTxId ?? this.originalTxId),
        date: date ?? this.date,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'account_id': accountId,
        'account_kind': accountKind.code,
        'type': type.code,
        'amount': amount,
        'currency': currency,
        'sign': sign,
        'from_id': fromId,
        'to_id': toId,
        'rate': rate,
        'description': description,
        'reference': reference,
        'notes': notes,
        'category': category,
        'attachment': attachment,
        'attachment_hash': attachmentHash,
        'image': image,
        'status': status,
        'sync_state': syncState,
        if (createdByUserId != null) 'created_by_user_id': createdByUserId,
        if (cashierName.isNotEmpty) 'cashier_name': cashierName,
        if (originalTxId != null && originalTxId!.isNotEmpty)
          'original_tx_id': originalTxId,
        'date': date.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Tx.fromMap(Map<String, Object?> m) => Tx(
        id: m['id'] as int?,
        accountId: m['account_id'] as int?,
        accountKind: AccountKind.fromCode(
          (m['account_kind'] ?? 'customer') as String,
        ),
        type: OpType.fromCode((m['type'] ?? 'debit') as String),
        amount: ((m['amount'] ?? 0) as num).toDouble(),
        currency: (m['currency'] ?? 'YER') as String,
        sign: (m['sign'] ?? '') as String,
        fromId: m['from_id'] as int?,
        toId: m['to_id'] as int?,
        rate: ((m['rate'] ?? 1) as num).toDouble(),
        description: (m['description'] ?? '') as String,
        reference: (m['reference'] ?? '') as String,
        notes: (m['notes'] ?? '') as String,
        category: (m['category'] ?? '') as String,
        attachment: (m['attachment'] ?? '') as String,
        attachmentHash: (m['attachment_hash'] ?? '') as String,
        image: (m['image'] ?? '') as String,
        status: (m['status'] ?? 'done') as String,
        syncState: (m['sync_state'] ?? 'synced') as String,
        createdByUserId: m['created_by_user_id'] as int?,
        cashierName: (m['cashier_name'] ?? '') as String,
        originalTxId: (m['original_tx_id'] == null ||
                '${m['original_tx_id']}'.trim().isEmpty)
            ? null
            : '${m['original_tx_id']}'.trim(),
        date: safeParseDateTime(m['date'], fallbackRaw: m['created_at']),
        createdAt: safeParseDateTime(m['created_at'], fallbackRaw: m['date']),
        updatedAt: safeParseDateTime(
          m['updated_at'],
          fallbackRaw: m['created_at'] ?? m['date'],
        ),
      );

  /// اسم العميل المخصص للفواتير النقدية المستخرج من الملاحظات أو الوصف.
  String? get customCustomerName =>
      extractCustomCustomerName(notes, description);

  /// اسم العميل/الحساب المحلول للعرض في البطاقات والتقارير والسندات والفواتير.
  String resolvedPartyName(Account? account, {String fallback = 'عميل نقدي'}) {
    final accName = account?.name.trim() ?? '';
    if (accName.isNotEmpty) return accName;
    final custom = customCustomerName;
    if (custom != null && custom.isNotEmpty) return custom;
    return fallback;
  }
}

/// يستخرج اسم العميل المخصص من حقل الملاحظات أو الوصف (مثل: `اسم العميل: أحمد`).
String? extractCustomCustomerName(String notes, [String description = '']) {
  for (final raw in <String>[notes, description]) {
    if (raw.trim().isEmpty) continue;
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.startsWith('اسم العميل:')) {
        final v = t.substring('اسم العميل:'.length).trim();
        if (v.isNotEmpty) return v;
      } else if (t.toLowerCase().startsWith('customer:')) {
        final v = t.substring('customer:'.length).trim();
        if (v.isNotEmpty) return v;
      }
    }
  }
  return null;
}

/// سطر صنف داخل فاتورة/عملية.
///
/// يُحفظ كسجل مستقل حتى تبقى تفاصيل البيع متاحة للنص والصورة والسند،
/// وحتى لا تُختزل الفاتورة في حقل الوصف فقط.
class InvoiceLine {
  final int? id;
  final int? txId;
  final int? itemId;
  final String name;
  final String unit;
  final double quantity;
  final double unitPrice;
  final double total;

  const InvoiceLine({
    this.id,
    this.txId,
    this.itemId,
    required this.name,
    this.unit = 'حبة',
    required this.quantity,
    required this.unitPrice,
    double? total,
  }) : total = total ?? quantity * unitPrice;

  Map<String, Object?> toMap({int? transactionId}) => {
        if (id != null) 'id': id,
        'tx_id': transactionId ?? txId,
        'item_id': itemId,
        'name': name,
        'unit': unit,
        'quantity': quantity,
        'unit_price': unitPrice,
        'total': total,
      };

  factory InvoiceLine.fromMap(Map<String, Object?> m) {
    final quantity = ((m['quantity'] ?? 0) as num).toDouble();
    final unitPrice = ((m['unit_price'] ?? 0) as num).toDouble();
    return InvoiceLine(
      id: m['id'] as int?,
      txId: m['tx_id'] as int?,
      itemId: m['item_id'] as int?,
      name: (m['name'] ?? '') as String,
      unit: (m['unit'] ?? 'حبة') as String,
      quantity: quantity,
      unitPrice: unitPrice,
      total: ((m['total'] ?? quantity * unitPrice) as num).toDouble(),
    );
  }
}

/// حساب مع رصيده المحسوب.
class AccountWithBalance {
  final Account account;
  final double balance;
  const AccountWithBalance(this.account, this.balance);

  /// هل تجاوز الحد الائتماني؟
  bool get overLimit {
    final l = account.creditLimit;
    return l != null && l > 0 && balance > l;
  }
}

// ==================== السندات ====================

/// أنواع السندات — نقل حرفي من `VOUCHER_TYPES` في نسخة الويب.
enum VoucherKind {
  receipt('سند قبض', '🧾', 'receipt', 'ق'),
  payment('سند صرف', '💳', 'payment', 'ص'),
  debit('سند قيد مدين', '📥', 'debit', 'ق'),
  credit('سند قيد دائن', '📤', 'credit', 'د'),
  transfer('سند تحويل', '🔁', 'transfer', 'تح');

  const VoucherKind(this.label, this.icon, this.code, this.prefix);
  final String label;
  final String icon;
  final String code;
  final String prefix;

  static VoucherKind fromCode(String c) => VoucherKind.values.firstWhere(
        (e) => e.code == c,
        orElse: () => VoucherKind.receipt,
      );

  /// (PR-3+) صياغة رقم السند ببادئة الجهاز لمنع التصادم [Prefix]-[Type]-[Sequence]
  String formatNumber({String? devicePrefix, required int sequence, int pad = 4}) {
    final pfx = (devicePrefix ?? '').trim().toUpperCase();
    final seqStr = sequence.toString().padLeft(pad, '0');
    if (pfx.isNotEmpty) {
      return '$pfx-$prefix-$seqStr';
    }
    return '$prefix$seqStr';
  }
}

class Voucher {
  final int? id;
  final String number;
  final VoucherKind kind;
  final int? accountId;
  final int? txId;
  final double amount;
  final String currency;
  final String statement;
  final String notes;

  /// draft / approved / cancelled
  final String status;
  final int? createdByUserId;
  final String cashierName;

  final DateTime date;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Voucher({
    this.id,
    required this.number,
    required this.kind,
    this.accountId,
    this.txId,
    required this.amount,
    this.currency = 'YER',
    this.statement = '',
    this.notes = '',
    this.status = 'draft',
    this.createdByUserId,
    this.cashierName = '',
    required this.date,
    required this.createdAt,
    required this.updatedAt,
  });

  String get statusLabel => switch (status) {
        'approved' => 'معتمد',
        'cancelled' => 'ملغى',
        _ => 'مسودة',
      };

  String? get customCustomerName =>
      extractCustomCustomerName(notes, statement);

  String resolvedPartyName(Account? account, {String fallback = 'عميل نقدي'}) {
    final accName = account?.name.trim() ?? '';
    if (accName.isNotEmpty) return accName;
    final custom = customCustomerName;
    if (custom != null && custom.isNotEmpty) return custom;
    return fallback;
  }

  Voucher copyWith({
    int? id,
    String? number,
    VoucherKind? kind,
    int? accountId,
    int? txId,
    double? amount,
    String? currency,
    String? statement,
    String? notes,
    String? status,
    int? createdByUserId,
    String? cashierName,
    DateTime? date,
    DateTime? updatedAt,
  }) =>
      Voucher(
        id: id ?? this.id,
        number: number ?? this.number,
        kind: kind ?? this.kind,
        accountId: accountId ?? this.accountId,
        txId: txId ?? this.txId,
        amount: amount ?? this.amount,
        currency: currency ?? this.currency,
        statement: statement ?? this.statement,
        notes: notes ?? this.notes,
        status: status ?? this.status,
        createdByUserId: createdByUserId ?? this.createdByUserId,
        cashierName: cashierName ?? this.cashierName,
        date: date ?? this.date,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'number': number,
        'kind': kind.code,
        'account_id': accountId,
        'tx_id': txId,
        'amount': amount,
        'currency': currency,
        'statement': statement,
        'notes': notes,
        'status': status,
        if (createdByUserId != null) 'created_by_user_id': createdByUserId,
        if (cashierName.isNotEmpty) 'cashier_name': cashierName,
        'date': date.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Voucher.fromMap(Map<String, Object?> m) => Voucher(
        id: m['id'] as int?,
        number: (m['number'] ?? '') as String,
        kind: VoucherKind.fromCode((m['kind'] ?? 'receipt') as String),
        accountId: m['account_id'] as int?,
        txId: m['tx_id'] as int?,
        amount: ((m['amount'] ?? 0) as num).toDouble(),
        currency: (m['currency'] ?? 'YER') as String,
        statement: (m['statement'] ?? '') as String,
        notes: (m['notes'] ?? '') as String,
        status: (m['status'] ?? 'draft') as String,
        createdByUserId: m['created_by_user_id'] as int?,
        cashierName: (m['cashier_name'] ?? '') as String,
        date: safeParseDateTime(m['date'], fallbackRaw: m['created_at']),
        createdAt: safeParseDateTime(m['created_at'], fallbackRaw: m['date']),
        updatedAt: safeParseDateTime(
          m['updated_at'],
          fallbackRaw: m['created_at'] ?? m['date'],
        ),
      );
}

// ==================== المستخدمون والصلاحيات ====================

/// الأدوار — نقل حرفي من `ROLES` في نسخة الويب.
enum UserRole {
  admin('مدير النظام', '👑', 'admin'),
  agent('وكيل المدير', '🛡️', 'agent'),
  accountant('محاسب', '🧮', 'accountant'),
  cashier('كاشير', '🛒', 'cashier'),
  dataentry('موظف إدخال', '⌨️', 'dataentry'),
  viewer('عرض فقط', '👁️', 'viewer');

  const UserRole(this.label, this.icon, this.code);
  final String label;
  final String icon;
  final String code;

  static UserRole fromCode(String c) {
    // توافق خلفي: البذرة القديمة كانت تستخدم 'manager' بدل 'admin'
    if (c == 'manager') return UserRole.admin;
    if (c == 'pos' || c == 'sales') return UserRole.cashier;
    return UserRole.values.firstWhere(
      (e) => e.code == c,
      orElse: () => UserRole.cashier,
    );
  }
}

/// الصلاحيات — نقل حرفي من `PERMS`.
class Perm {
  final String key;
  final String label;
  const Perm(this.key, this.label);
}

const kPerms = <Perm>[
  Perm('add_tx', 'إضافة العمليات'),
  Perm('edit_tx', 'تعديل العمليات'),
  Perm('delete_tx', 'حذف العمليات'),
  Perm('view_reports', 'عرض التقارير'),
  Perm('can_view_sales_summary', 'عرض ملخص وتقارير المبيعات'),
  Perm('export', 'تصدير البيانات'),
  Perm('manage_backup', 'إدارة النسخ الاحتياطي'),
  Perm('manage_users', 'إدارة المستخدمين'),
  Perm('approve_vouchers', 'اعتماد/إلغاء السندات'),
  Perm('manage_currencies', 'إدارة العملات'),
];

/// الصلاحيات الافتراضية لكل دور — منقولة حرفيًا من `defaultPerms`.
Map<String, bool> defaultPerms(UserRole role) {
  switch (role) {
    case UserRole.admin:
      return {for (final p in kPerms) p.key: true};
    // الوكيل يقوم بعمل المدير أثناء غيابه: كل الصلاحيات افتراضياً.
    case UserRole.agent:
      return {for (final p in kPerms) p.key: true};
    case UserRole.accountant:
      return {
        'add_tx': true,
        'edit_tx': true,
        'delete_tx': false,
        'view_reports': true,
        'can_view_sales_summary': true,
        'export': true,
        'approve_vouchers': true,
        'manage_currencies': true,
        'manage_backup': false,
        'manage_users': false,
      };
    case UserRole.cashier:
      return {
        'add_tx': true,
        'edit_tx': false,
        'delete_tx': false,
        'view_reports': false,
        'can_view_sales_summary': false,
        'export': false,
        'approve_vouchers': false,
        'manage_currencies': false,
        'manage_backup': false,
        'manage_users': false,
      };
    case UserRole.dataentry:
      return {
        'add_tx': true,
        'edit_tx': true,
        'delete_tx': false,
        'view_reports': false,
        'can_view_sales_summary': false,
        'export': false,
        'approve_vouchers': false,
        'manage_currencies': false,
        'manage_backup': false,
        'manage_users': false,
      };
    case UserRole.viewer:
      return {
        'add_tx': false,
        'edit_tx': false,
        'delete_tx': false,
        'view_reports': true,
        'can_view_sales_summary': false,
        'export': false,
        'approve_vouchers': false,
        'manage_currencies': false,
        'manage_backup': false,
        'manage_users': false,
      };
  }
}

class AppUser {
  final int? id;
  final String name;

  /// (3.70) البريد — مفتاح RBAC في user_permissions (فارغ لصفوف قديمة).
  final String email;
  final UserRole role;
  final String pin;

  /// تجزئة كلمة مرور المستخدم (SHA-256). فارغة = بلا حماية.
  final String password;
  final Map<String, bool> permissions;
  final bool isMe;
  final bool active;
  final bool canApplyDiscount;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AppUser({
    this.id,
    required this.name,
    this.email = '',
    this.role = UserRole.cashier,
    this.pin = '',
    this.password = '',
    this.permissions = const {},
    this.isMe = false,
    this.active = true,
    this.canApplyDiscount = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// هل يحتاج التبديل إلى هذا المستخدم كلمة مرور؟
  bool get locked => password.isNotEmpty;

  /// هل يملك دور المدير أو وكيل المدير حصراً؟
  bool get isManagerOrAgent =>
      role == UserRole.admin || role == UserRole.agent;

  /// المدير والوكيل لهما كل شيء دائمًا — وحذف العمليات محصور بهما فقط.
  bool can(String perm) {
    if (role == UserRole.admin || role == UserRole.agent) return true;
    if (perm == 'delete_tx' || perm == 'can_delete_tx') return false;
    if (perm == 'can_discount') {
      return canApplyDiscount || (permissions['can_discount'] ?? false);
    }
    if (permissions.isEmpty) {
      return defaultPerms(role)[perm] ?? false;
    }
    return permissions[perm] ?? false;
  }

  String get permSummary {
    if (role == UserRole.admin) return 'جميع الصلاحيات';
    final granted =
        kPerms.where((p) => permissions[p.key] == true).map((p) => p.label);
    if (granted.isEmpty) return 'لا صلاحيات';
    return granted.join('، ');
  }

  AppUser copyWith({
    int? id,
    String? name,
    String? email,
    UserRole? role,
    String? pin,
    String? password,
    Map<String, bool>? permissions,
    bool? isMe,
    bool? active,
    bool? canApplyDiscount,
    DateTime? updatedAt,
  }) =>
      AppUser(
        id: id ?? this.id,
        name: name ?? this.name,
        email: email ?? this.email,
        role: role ?? this.role,
        pin: pin ?? this.pin,
        password: password ?? this.password,
        permissions: permissions ?? this.permissions,
        isMe: isMe ?? this.isMe,
        active: active ?? this.active,
        canApplyDiscount: canApplyDiscount ?? this.canApplyDiscount,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'email': email,
        'role': role.code,
        'pin': pin,
        'password': password,
        'permissions': permissions.entries
            .where((e) => e.value)
            .map((e) => e.key)
            .join(','),
        'is_me': isMe ? 1 : 0,
        'active': active ? 1 : 0,
        'can_apply_discount': canApplyDiscount ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory AppUser.fromMap(Map<String, Object?> m) {
    final raw = ((m['permissions'] ?? '') as String)
        .split(',')
        .where((s) => s.trim().isNotEmpty)
        .toSet();
    final role = UserRole.fromCode((m['role'] ?? 'cashier') as String);
    final discountDefault = role == UserRole.admin || role == UserRole.agent;
    final permsMap = raw.isEmpty
        ? defaultPerms(role)
        : {for (final p in kPerms) p.key: raw.contains(p.key)};
    return AppUser(
      id: m['id'] as int?,
      name: (m['name'] ?? '') as String,
      email: '${m['email'] ?? ''}',
      role: role,
      pin: (m['pin'] ?? '') as String,
      password: (m['password'] ?? '') as String,
      permissions: permsMap,
      isMe: ((m['is_me'] ?? 0) as int) == 1,
      active: ((m['active'] ?? 1) as int) == 1,
      canApplyDiscount: ((m['can_apply_discount'] ?? (discountDefault ? 1 : 0)) as int) == 1,
      createdAt: safeParseDateTime(m['created_at'], fallbackRaw: m['updated_at']),
      updatedAt: safeParseDateTime(m['updated_at'], fallbackRaw: m['created_at']),
    );
  }
}

// ==================== الدردشة ====================

class ChatMessage {
  final int? id;
  final int conversationId;
  final String sender;
  final String body;

  /// text / statement / voucher
  final String kind;
  final String payload;
  final DateTime createdAt;

  const ChatMessage({
    this.id,
    required this.conversationId,
    this.sender = '',
    this.body = '',
    this.kind = 'text',
    this.payload = '',
    required this.createdAt,
  });

  bool get isMine => sender == 'me';

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'conversation_id': conversationId,
        'sender': sender,
        'body': body,
        'kind': kind,
        'payload': payload,
        'created_at': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
        id: m['id'] as int?,
        conversationId: (m['conversation_id'] ?? 0) as int,
        sender: (m['sender'] ?? '') as String,
        body: (m['body'] ?? '') as String,
        kind: (m['kind'] ?? 'text') as String,
        payload: (m['payload'] ?? '') as String,
        createdAt: safeParseDateTime(m['created_at']),
      );
}

// ==================== المخزون والأصناف ====================

/// نوع حركة المخزون.
enum StockKind {
  purchase('purchase', 'شراء'),
  sale('sale', 'بيع'),
  adjust('adjust', 'تسوية'),
  ret('return', 'مرتجع');

  final String code;
  final String label;
  const StockKind(this.code, this.label);

  static StockKind fromCode(String c) => StockKind.values.firstWhere(
        (e) => e.code == c,
        orElse: () => StockKind.purchase,
      );

  /// إشارة تأثير الحركة على الكمية المتبقية.
  int get qtySign => switch (this) {
        StockKind.purchase => 1,
        StockKind.ret => 1,
        StockKind.sale => -1,
        StockKind.adjust => 1,
      };
}

/// فئة/قسم أصناف داخل المخزون.
///
/// الفئات مستقلة عن تصنيفات الحسابات، ويمكن إنشاء عدد غير محدود منها.
/// (2026-09-22) معرّف افتراضي لمجموعة «عام»: الفئات بلا قسم تُعرض تحته
/// (ليس صفاً حقيقياً في جدول sections بل تجميعة عرض).
const int kGeneralSectionId = -1;

/// (2026-09-22) قسم المتجر — المستوى الأول في هرمية:
/// القسم (إلكترونيات/ملابس/…) ← الفئة ← الصنف.
class Section {
  final int? id;
  final String name;

  /// (قديم) رمز تعبيري مخزّن في عمود `icon` — يُبقى للتوافق مع البيانات القديمة.
  final String icon;

  /// (2026-09-24) مفتاح الأيقونة من `IconCatalog` (مثال: `tools`, `phone`).
  final String iconKey;

  /// (2026-09-24) لون الكرت بصيغة HEX (مثال: `#0D6EFD`) أو مفتاح نغمة
  /// باستيل (مثال: `blue`). فارغ ⇒ اللون الافتراضي.
  final String colorHex;

  /// (2026-09-24) مسار صورة اختيارية تظهر أعلى كرت القسم.
  final String imagePath;

  final int sortOrder;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Section({
    this.id,
    required this.name,
    this.icon = '',
    this.iconKey = '',
    this.colorHex = '',
    this.imagePath = '',
    this.sortOrder = 0,
    this.deleted = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// الأيقونة الفعالة: المفتاح الحديث إن وُجد، وإلا الرمز القديم.
  String get effectiveIcon => iconKey.isNotEmpty ? iconKey : icon;

  Section copyWith({
    int? id,
    String? name,
    String? icon,
    String? iconKey,
    String? colorHex,
    String? imagePath,
    int? sortOrder,
    bool? deleted,
    DateTime? updatedAt,
  }) =>
      Section(
        id: id ?? this.id,
        name: name ?? this.name,
        icon: icon ?? this.icon,
        iconKey: iconKey ?? this.iconKey,
        colorHex: colorHex ?? this.colorHex,
        imagePath: imagePath ?? this.imagePath,
        sortOrder: sortOrder ?? this.sortOrder,
        deleted: deleted ?? this.deleted,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'icon': icon,
        'icon_key': iconKey,
        'color_hex': colorHex,
        'image_path': imagePath,
        'sort_order': sortOrder,
        'deleted_at': deleted ? updatedAt.toIso8601String() : '',
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Section.fromMap(Map<String, Object?> m) {
    final created = safeParseDateTime(
      m['created_at'],
      fallbackRaw: m['updated_at'],
      fallback: DateTime.now(),
    );
    return Section(
      id: (m['id'] as num?)?.toInt(),
      name: '${m['name'] ?? ''}',
      icon: '${m['icon'] ?? ''}',
      iconKey: '${m['icon_key'] ?? ''}',
      colorHex: '${m['color_hex'] ?? ''}',
      imagePath: '${m['image_path'] ?? ''}',
      sortOrder: ((m['sort_order'] ?? 0) as num).toInt(),
      deleted: '${m['deleted_at'] ?? ''}'.trim().isNotEmpty,
      createdAt: created,
      updatedAt: safeParseDateTime(m['updated_at'], fallback: created),
    );
  }
}

class ItemCategory {
  final int? id;

  /// (2026-09-22) الفئة الأب — null تعني فئة رئيسية (جذر في الشجرة).
  final int? parentId;

  /// (2026-09-22) القسم الذي تتبعه هذه الفئة — null ⇒ «عام/بدون قسم».
  final int? sectionId;
  final String name;

  /// (2026-09-24) مفتاح الأيقونة من `IconCatalog`.
  final String iconKey;

  /// (2026-09-24) لون الكرت (HEX أو مفتاح نغمة باستيل).
  final String colorHex;

  /// (2026-09-24) مسار صورة اختيارية للفئة.
  final String imagePath;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// (2026-09-22) الفئات الفرعية المباشرة — تُملأ في طبقة العرض عند
  /// بناء الشجرة، ولا تُخزَّن في قاعدة البيانات (مشتقة من parent_id).
  final List<ItemCategory> children;

  const ItemCategory({
    this.id,
    this.parentId,
    this.sectionId,
    required this.name,
    this.iconKey = '',
    this.colorHex = '',
    this.imagePath = '',
    required this.createdAt,
    required this.updatedAt,
    this.children = const [],
  });

  /// فئة رئيسية (جذر) إن لم يكن لها أب.
  bool get isRoot => parentId == null;

  /// بلا قسم محدد ⇒ تُعرض تحت «عام».
  bool get withoutSection => sectionId == null;

  /// هل لها فئات فرعية؟
  bool get hasChildren => children.isNotEmpty;

  /// (3.98.41) جمع كل معرفات الفئات الأحفاد والتابعة شجرياً لأي عمق.
  Set<int> get allDescendantIds {
    final ids = <int>{};
    void collect(ItemCategory cat) {
      for (final child in cat.children) {
        if (child.id != null) {
          ids.add(child.id!);
          collect(child);
        }
      }
    }
    collect(this);
    return ids;
  }

  /// المعرف الذاتي مضافاً إليه كل معرفات الأحفاد شجرياً.
  Set<int> get selfAndAllDescendantIds {
    final ids = <int>{};
    if (id != null) ids.add(id!);
    ids.addAll(allDescendantIds);
    return ids;
  }

  ItemCategory copyWith({
    int? id,
    int? parentId,
    bool clearParentId = false,
    int? sectionId,
    bool clearSectionId = false,
    String? name,
    String? iconKey,
    String? colorHex,
    String? imagePath,
    DateTime? updatedAt,
    List<ItemCategory>? children,
  }) =>
      ItemCategory(
        id: id ?? this.id,
        parentId: clearParentId ? null : (parentId ?? this.parentId),
        sectionId: clearSectionId ? null : (sectionId ?? this.sectionId),
        name: name ?? this.name,
        iconKey: iconKey ?? this.iconKey,
        colorHex: colorHex ?? this.colorHex,
        imagePath: imagePath ?? this.imagePath,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        children: children ?? this.children,
      );

  /// يربط الأبناء بهذه الفئة (نسخة جديدة للواجهة الثابتة).
  ItemCategory withChildren(List<ItemCategory> subs) =>
      copyWith(children: subs);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        if (parentId != null) 'parent_id': parentId,
        if (sectionId != null) 'section_id': sectionId,
        'icon_key': iconKey,
        'color_hex': colorHex,
        'image_path': imagePath,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ItemCategory.fromMap(Map<String, Object?> m) {
    final created = safeParseDateTime(
      m['created_at'],
      fallbackRaw: m['updated_at'],
    );
    return ItemCategory(
      id: (m['id'] as num?)?.toInt(),
      parentId: (m['parent_id'] as num?)?.toInt(),
      sectionId: (m['section_id'] as num?)?.toInt(),
      name: '${m['name'] ?? ''}',
      iconKey: '${m['icon_key'] ?? ''}',
      colorHex: '${m['color_hex'] ?? ''}',
      imagePath: '${m['image_path'] ?? ''}',
      createdAt: created,
      updatedAt: safeParseDateTime(m['updated_at'], fallback: created),
    );
  }
}

/// صنف في المخزون.
class Item {
  final int? id;
  final String name;
  final int? categoryId;

  /// (2026-09-22) القسم الذي يتبعه الصنف (يُشتق من فئته إن لم يُحدَّد).
  final int? sectionId;

  /// (2026-09-24) **رقم الترقيم السريع (PLU)**: رقم تسلسلي فريد وثابت
  /// يتولّد مرة واحدة عند إضافة الصنف ويبقى للأبد — لا يتغيّر بإعادة
  /// الترتيب أو الفرز (أبجدي/سعر/كمية) ولا يُعاد استخدامه بعد الحذف.
  final int? plu;
  final String sku;
  final String unit;
  final double buyPrice;
  final double sellPrice;
  final double quantity;
  final double minQuantity;
  final String currency;
  final String category;
  final String notes;
  final String image;
  final bool archived;
  final bool isDeleted;
  final bool isActive;
  final bool excludeFromShortages;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Item({
    this.id,
    required this.name,
    this.categoryId,
    this.sectionId,
    this.plu,
    this.sku = '',
    this.unit = 'حبة',
    this.buyPrice = 0,
    this.sellPrice = 0,
    this.quantity = 0,
    this.minQuantity = 0,
    this.currency = 'YER',
    this.category = '',
    this.notes = '',
    this.image = '',
    this.archived = false,
    this.isDeleted = false,
    this.isActive = true,
    this.excludeFromShortages = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// ربح الوحدة الواحدة.
  double get unitProfit => sellPrice - buyPrice;

  /// نسبة الربح إلى سعر الشراء (٪).
  double get marginPercent => buyPrice <= 0 ? 0 : (unitProfit / buyPrice) * 100;

  /// قيمة المخزون بسعر الشراء.
  double get stockCost => buyPrice * quantity;

  /// قيمة المخزون بسعر البيع.
  double get stockValue => sellPrice * quantity;

  /// الربح المتوقع لو بيع كل المتبقي.
  double get expectedProfit => unitProfit * quantity;

  bool get low => minQuantity > 0 && quantity <= minQuantity;
  bool get out => quantity <= 0;

  Item copyWith({
    int? id,
    String? name,
    int? categoryId,
    bool clearCategoryId = false,
    int? sectionId,
    bool clearSectionId = false,
    int? plu,
    String? sku,
    String? unit,
    double? buyPrice,
    double? sellPrice,
    double? quantity,
    double? minQuantity,
    String? currency,
    String? category,
    String? notes,
    String? image,
    bool? archived,
    bool? isDeleted,
    bool? isActive,
    bool? excludeFromShortages,
  }) =>
      Item(
        id: id ?? this.id,
        name: name ?? this.name,
        categoryId: clearCategoryId ? null : (categoryId ?? this.categoryId),
        sectionId: clearSectionId ? null : (sectionId ?? this.sectionId),
        plu: plu ?? this.plu,
        sku: sku ?? this.sku,
        unit: unit ?? this.unit,
        buyPrice: buyPrice ?? this.buyPrice,
        sellPrice: sellPrice ?? this.sellPrice,
        quantity: quantity ?? this.quantity,
        minQuantity: minQuantity ?? this.minQuantity,
        currency: currency ?? this.currency,
        category: category ?? this.category,
        notes: notes ?? this.notes,
        image: image ?? this.image,
        archived: archived ?? this.archived,
        isDeleted: isDeleted ?? this.isDeleted,
        isActive: isActive ?? this.isActive,
        excludeFromShortages: excludeFromShortages ?? this.excludeFromShortages,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'category_id': categoryId,
        if (sectionId != null) 'section_id': sectionId,
        if (plu != null) 'plu': plu,
        'sku': sku,
        'unit': unit,
        'buy_price': buyPrice,
        'sell_price': sellPrice,
        'quantity': quantity,
        'min_quantity': minQuantity,
        'currency': currency,
        'category': category,
        'notes': notes,
        'image': image,
        'archived': archived ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'is_active': isActive ? 1 : 0,
        'exclude_from_shortages': excludeFromShortages ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Item.fromMap(Map<String, Object?> m) {
    final created = safeParseDateTime(
      m['created_at'],
      fallbackRaw: m['updated_at'],
    );
    return Item(
      id: (m['id'] as num?)?.toInt(),
      name: '${m['name'] ?? ''}',
      categoryId: (m['category_id'] as num?)?.toInt(),
      sectionId: (m['section_id'] as num?)?.toInt(),
      plu: (m['plu'] as num?)?.toInt(),
      sku: '${m['sku'] ?? ''}',
      unit: '${m['unit'] ?? 'حبة'}',
      buyPrice: ((m['buy_price'] ?? 0) as num).toDouble(),
      sellPrice: ((m['sell_price'] ?? 0) as num).toDouble(),
      quantity: ((m['quantity'] ?? 0) as num).toDouble(),
      minQuantity: ((m['min_quantity'] ?? 0) as num).toDouble(),
      currency: '${m['currency'] ?? 'YER'}',
      category: '${m['category_name'] ?? m['category'] ?? ''}',
      notes: '${m['notes'] ?? ''}',
      image: '${m['image'] ?? ''}',
      archived: ((m['archived'] ?? 0) as num).toInt() == 1,
      isDeleted: ((m['is_deleted'] ?? 0) as num).toInt() == 1 ||
          (m['deleted_at'] != null &&
              '${m['deleted_at']}'.trim().isNotEmpty &&
              '${m['deleted_at']}'.trim().toLowerCase() != 'null'),
      isActive: ((m['is_active'] ?? 1) as num).toInt() == 1,
      excludeFromShortages:
          ((m['exclude_from_shortages'] ?? 0) as num).toInt() == 1,
      createdAt: created,
      updatedAt: safeParseDateTime(m['updated_at'], fallback: created),
    );
  }
}

/// حركة مخزنية (شراء/بيع/تسوية/مرتجع).
class StockMove {
  final int? id;
  final int itemId;
  final StockKind kind;
  final double quantity;
  final double unitPrice;
  final int? accountId;
  final String notes;
  final DateTime date;
  final DateTime createdAt;

  const StockMove({
    this.id,
    required this.itemId,
    required this.kind,
    required this.quantity,
    this.unitPrice = 0,
    this.accountId,
    this.notes = '',
    required this.date,
    required this.createdAt,
  });

  double get total => quantity * unitPrice;

  /// الربح المحقق: يُحسب للبيع فقط، مقابل سعر الشراء الممرّر.
  double profitAgainst(double buyPrice) =>
      kind == StockKind.sale ? (unitPrice - buyPrice) * quantity : 0;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'item_id': itemId,
        'kind': kind.code,
        'quantity': quantity,
        'unit_price': unitPrice,
        'account_id': accountId,
        'notes': notes,
        'date': date.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
      };

  factory StockMove.fromMap(Map<String, Object?> m) {
    final d = safeParseDateTime(m['date'], fallbackRaw: m['created_at']);
    return StockMove(
      id: (m['id'] as num?)?.toInt(),
      itemId: ((m['item_id'] ?? 0) as num).toInt(),
      kind: StockKind.fromCode('${m['kind'] ?? 'purchase'}'),
      quantity: ((m['quantity'] ?? 0) as num).toDouble(),
      unitPrice: ((m['unit_price'] ?? 0) as num).toDouble(),
      accountId: (m['account_id'] as num?)?.toInt(),
      notes: '${m['notes'] ?? ''}',
      date: d,
      createdAt: safeParseDateTime(m['created_at'], fallback: d),
    );
  }
}
