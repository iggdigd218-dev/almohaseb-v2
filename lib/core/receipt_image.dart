import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'theme.dart';
import 'package:path_provider/path_provider.dart';

import 'accounting.dart';
import 'format.dart';
import 'media_paths.dart';
import 'models.dart';
import 'words.dart';

/// بيانات الإيصال المرسوم كصورة.
class ReceiptData {
  final String title;
  final String number;
  final String accountName;
  final String accountPhone;
  final double amount;
  final CurrencyDef currency;
  final String statement;
  final String notes;
  final DateTime date;
  final double? balanceAfter;
  final String orgName;
  final String orgAddress;
  final String orgPhone;
  final String sellerOrDevice;
  final String logoPath;
  final String logoBase64;
  final String footer;
  final List<InvoiceLine> items;
  final bool isDebit;
  final bool isCashSale;

  const ReceiptData({
    required this.title,
    this.number = '',
    required this.accountName,
    this.accountPhone = '',
    required this.amount,
    required this.currency,
    this.statement = '',
    this.notes = '',
    required this.date,
    this.balanceAfter,
    this.orgName = '',
    this.orgAddress = '',
    this.orgPhone = '',
    this.sellerOrDevice = '',
    this.logoPath = '',
    this.logoBase64 = '',
    this.footer = '',
    this.items = const [],
    this.isDebit = true,
    this.isCashSale = false,
  });

  static String _resolveSellerOrDevice(
    String cashierName,
    Map<String, String> settings,
  ) {
    final c = cashierName.trim();
    final devName = (settings['sync.deviceName'] ?? '').trim();
    final rawDevId = (settings['sync.deviceId'] ?? '').trim();
    final devCode = Fmt.singleLetterDevicePrefix(
      rawDevId,
      configuredPrefix: settings['devicePrefix'],
    );
    if (c.isNotEmpty && devCode.isNotEmpty && !c.contains('($devCode)')) {
      return '$c ($devCode)';
    }
    if (c.isNotEmpty) return c;
    if (devName.isNotEmpty) {
      return devCode.isNotEmpty && !devName.contains('($devCode)')
          ? '$devName ($devCode)'
          : devName;
    }
    if (devCode.isNotEmpty) return 'المدير ($devCode)';
    return 'المدير';
  }

  factory ReceiptData.fromTx({
    required Tx tx,
    required Account? account,
    required CurrencyDef currency,
    double? balanceAfter,
    required Map<String, String> settings,
    List<InvoiceLine> items = const [],
  }) =>
      ReceiptData(
        title: tx.type == OpType.revenue
            ? 'فاتورة نقدية مدفوعة'
            : (tx.type == OpType.debit && items.isNotEmpty
                ? (tx.notes.contains('المبلغ المدفوع:')
                    ? 'فاتورة مبيعات (دفع جزئي)'
                    : 'فاتورة مبيع آجل')
                : tx.type.label),
        number: tx.reference,
        accountName: account?.name ?? 'عميل نقدي',
        accountPhone: account?.phone ?? '',
        amount: tx.amount,
        currency: currency,
        statement: tx.description,
        notes: tx.notes,
        date: tx.date,
        balanceAfter: balanceAfter,
        orgName: (settings['businessName'] ?? settings['org.name'] ?? '').trim(),
        orgAddress: (settings['address'] ?? settings['org.address'] ?? '').trim(),
        orgPhone: (settings['phone'] ?? '').trim(),
        sellerOrDevice: _resolveSellerOrDevice(tx.cashierName, settings),
        logoPath: (settings['logo'] ??
                settings['logoPath'] ??
                settings['account.photoPath'] ??
                '')
            .trim(),
        logoBase64:
            (settings['org.icon.b64'] ?? settings['logoBase64'] ?? '').trim(),
        footer: settings['voucherFooter'] ?? '',
        items: items,
        // المبلغ عليه (مدين/صرف/مصروف) = أحمر؛ له (قبض/دائن) = أخضر.
        isDebit: tx.type == OpType.debit ||
            tx.type == OpType.outflow ||
            tx.type == OpType.expense,
        isCashSale: tx.type == OpType.revenue,
      );

  factory ReceiptData.fromVoucher({
    required Voucher v,
    required Account? account,
    required CurrencyDef currency,
    double? balanceAfter,
    required Map<String, String> settings,
    List<InvoiceLine> items = const [],
  }) =>
      ReceiptData(
        title: v.kind.label,
        number: v.number,
        accountName: account?.name ?? '—',
        accountPhone: account?.phone ?? '',
        amount: v.amount,
        currency: currency,
        statement: v.statement,
        notes: v.notes,
        date: v.date,
        balanceAfter: balanceAfter,
        orgName: (settings['businessName'] ?? settings['org.name'] ?? '').trim(),
        orgAddress: (settings['address'] ?? settings['org.address'] ?? '').trim(),
        orgPhone: (settings['phone'] ?? '').trim(),
        sellerOrDevice: _resolveSellerOrDevice(v.cashierName, settings),
        logoPath: (settings['logo'] ??
                settings['logoPath'] ??
                settings['account.photoPath'] ??
                '')
            .trim(),
        logoBase64:
            (settings['org.icon.b64'] ?? settings['logoBase64'] ?? '').trim(),
        footer: settings['voucherFooter'] ?? '',
        items: items,
        isDebit: v.kind == VoucherKind.payment,
      );
}

/// يرسم الإيصال كصورة PNG عرضية (3:2 Landscape Full-Canvas) ويحفظه في مجلد مؤقت.
///
/// نرسم عبر `PictureRecorder` مباشرة بدل التقاط عنصر من الشجرة، فالصورة
/// تُولَّد حتى لو لم تُعرض أي واجهة — وهذا شرط الإرسال التلقائي.
Future<String> buildReceiptImage(ReceiptData d) async {
  const w = 1200.0;
  const outerPad = 14.0;
  const cardX = outerPad;
  const cardW = w - outerPad * 2;
  const pad = outerPad + 32.0; // 46.0 من حافة الصورة

  // استخراج المبلغ المدفوع والمتبقي في حال البيع الجزئي
  String? paidVal;
  String? remainVal;
  final extraNotes = <String>[];
  for (final l in d.notes.split('\n')) {
    final t = l.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('[ORIG_TX:')) continue;
    if (t.startsWith('المبلغ المدفوع:')) {
      paidVal = t.substring('المبلغ المدفوع:'.length).trim();
    } else if (t.startsWith('المبلغ المتبقي:')) {
      remainVal = t.substring('المبلغ المتبقي:'.length).trim();
    } else {
      extraNotes.add(t);
    }
  }

  ui.Image? logo;
  Uint8List? logoBytes;
  if (d.logoBase64.trim().isNotEmpty) {
    try {
      logoBytes = base64Decode(d.logoBase64.trim());
    } catch (_) {}
  }
  if (logoBytes == null &&
      d.logoPath.trim().isNotEmpty &&
      !d.logoPath.trim().startsWith('http')) {
    try {
      final file = File(MediaPaths.toAbsolute(d.logoPath.trim()));
      if (await file.exists()) {
        logoBytes = await file.readAsBytes();
      }
    } catch (_) {}
  }
  if (logoBytes != null && logoBytes.isNotEmpty) {
    try {
      final codec = await ui.instantiateImageCodec(logoBytes);
      logo = (await codec.getNextFrame()).image;
    } catch (_) {
      // شعار غير صالح لا يمنع إنشاء السند؛ نتابع من دون صورة.
    }
  }

  final rawStmt = d.statement.trim();
  final combinedNotes = extraNotes.join(' — ').trim();
  final String fullStatement;
  if (rawStmt.isNotEmpty &&
      combinedNotes.isNotEmpty &&
      rawStmt != combinedNotes) {
    fullStatement = '$rawStmt — $combinedNotes';
  } else if (rawStmt.isNotEmpty) {
    fullStatement = rawStmt;
  } else if (combinedNotes.isNotEmpty) {
    fullStatement = combinedNotes;
  } else {
    fullStatement = d.title;
  }

  const headerH = 152.0;
  const metaH = 104.0;
  const midGridH = 176.0;
  const singleStatementH = 66.0;
  const tableTitleH = 48.0;
  const tableHeaderH = 46.0;
  const tableRowH = 48.0;
  const tableFooterH = 52.0;
  const footerH = 74.0;

  final hasPartialBar =
      (paidVal != null && paidVal.isNotEmpty) ||
      (remainVal != null && remainVal.isNotEmpty);
  final partialBarH = hasPartialBar ? 58.0 : 0.0;

  // إذا كانت فاتورة مبيعات/مرتجع تتضمن أصنافاً، يظهر البيان كجدول يتمدد ارتفاعه حسب عدد الأصناف
  final statementSectionH = d.items.isEmpty
      ? singleStatementH
      : (tableTitleH +
          tableHeaderH +
          (d.items.length * tableRowH) +
          tableFooterH);

  final cardH = headerH +
      22.0 + // مسافة أعلى صندوق بيانات العميل
      metaH +
      20.0 + // مسافة أعلى شبكة المبلغ والرصيد
      midGridH +
      20.0 + // مسافة أعلى قسم البيان / جدول الأصناف
      statementSectionH +
      (hasPartialBar ? (14.0 + partialBarH) : 0.0) +
      24.0 + // مسافة أعلى الخط المنقط والتذييل
      footerH;

  final height = cardH + outerPad * 2;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, height));

  const ink = Color(0xFF0F172A); // نص أساسي داكن
  const muted = Color(0xFF475569); // عناوين رمادية
  const line = Color(0xFFCBD5E1); // حدود واضحة ناعمة
  const green = Color(0xFF15803D); // أخضر «له»
  const red = Color(0xFFB91C1C); // أحمر «عليه»
  const skyDark = Color(0xFF0284C7); // سماوي جذاب رئيسي
  const skyBright = Color(0xFF0EA5E9); // سماوي مشرق

  // خلفية خارجية ناعمة جداً
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w, height),
    Paint()..color = const Color(0xFFF1F5F9),
  );

  // جسم البطاقة الرئيسي بحواف دائرية أنيقة
  final cardRRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(cardX, outerPad, cardW, cardH),
    const Radius.circular(24),
  );
  canvas.drawRRect(cardRRect, Paint()..color = Colors.white);

  // قص الترويسة العلوية لتأخذ انحناء البطاقة من الأعلى
  canvas.save();
  canvas.clipRRect(cardRRect);

  // ===== 1) الترويسة العلوية باللون السماوي الجذاب (Attractive Sky Blue Gradient) =====
  const headerRect = Rect.fromLTWH(cardX, outerPad, cardW, headerH);
  final headerPaint = Paint()
    ..shader = ui.Gradient.linear(
      const Offset(cardX + cardW, outerPad),
      const Offset(cardX, outerPad + headerH),
      const [
        Color(0xFF0EA5E9), // Sky 500 الجذاب المشرق
        Color(0xFF0284C7), // Sky 600
        Color(0xFF0369A1), // Sky 700
      ],
      const [0.0, 0.55, 1.0],
    );
  canvas.drawRect(headerRect, headerPaint);

  // شريط سفلي سماوي مضيء أسفل الترويسة
  canvas.drawRect(
    const Rect.fromLTWH(cardX, outerPad + headerH - 6, cardW, 6),
    Paint()..color = const Color(0xFF38BDF8),
  );

  // --- وسط الترويسة تماماً: أيقونة / شعار المنشأة في دائرة في أعلى الوسط ---
  const centerX = w / 2;
  const circleCenterY = outerPad + (headerH - 6) / 2;
  const circleRadius = 46.0;
  const circleCenter = Offset(centerX, circleCenterY);

  // هالة خارجية شفافة حول دائرة الشعار
  canvas.drawCircle(
    circleCenter,
    circleRadius + 6,
    Paint()..color = Colors.white.withValues(alpha: 0.22),
  );
  // الدائرة البيضاء الحاضنة لأيقونة المنشأة
  canvas.drawCircle(
    circleCenter,
    circleRadius,
    Paint()..color = Colors.white,
  );
  canvas.drawCircle(
    circleCenter,
    circleRadius,
    Paint()
      ..color = const Color(0xFF7DD3FC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5,
  );

  if (logo != null) {
    canvas.save();
    final clipPath = Path()
      ..addOval(Rect.fromCircle(center: circleCenter, radius: circleRadius - 3));
    canvas.clipPath(clipPath);
    canvas.drawImageRect(
      logo,
      Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      Rect.fromCircle(center: circleCenter, radius: circleRadius - 3),
      Paint()..filterQuality = ui.FilterQuality.high,
    );
    canvas.restore();
  } else {
    // أيقونة المنشأة الافتراضية داخل الدائرة في حال عدم تحديد صورة شعار
    _text(
      canvas,
      '🏪',
      centerX,
      circleCenterY - 26,
      38,
      skyDark,
       bold: true,
      center: true,
    );
  }

  // --- يمين الترويسة: اسم المنشأة + العنوان والهاتف ---
  const rightSideMaxW = (cardW / 2) - circleRadius - 48.0;
  final orgTitle = d.orgName.isEmpty ? 'المحاسب' : d.orgName;
  _text(
    canvas,
    '⚡ $orgTitle',
    w - pad,
    outerPad + 28,
    30,
    Colors.white,
    bold: true,
    alignEnd: true,
    maxWidth: rightSideMaxW,
  );

  final addrPart = d.orgAddress.trim().isNotEmpty
      ? '📍 ${d.orgAddress.trim()}'
      : '📍 المركز الرئيسي';
  final phonePart =
      d.orgPhone.trim().isNotEmpty ? 'هاتف: ${d.orgPhone.trim()}' : '';
  final subHeaderRight =
      phonePart.isNotEmpty ? '$addrPart   •   $phonePart' : addrPart;

  _text(
    canvas,
    subHeaderRight,
    w - pad,
    outerPad + 84,
    19,
    Colors.white.withValues(alpha: 0.95),
    bold: true,
    alignEnd: true,
    maxWidth: rightSideMaxW,
  );

  // --- يسار الترويسة: شارة نوع السند + الرقم المرجعي بالأصفر + التاريخ والوقت ---
  final badgeLabel =
      d.title.trim().isEmpty ? 'سند قيد إلكتروني' : d.title.trim();
  const badgeW = 210.0;
  const badgeH = 38.0;
  final badgeRect = RRect.fromRectAndRadius(
    const Rect.fromLTWH(pad, outerPad + 18, badgeW, badgeH),
    const Radius.circular(10),
  );
  canvas.drawRRect(
    badgeRect,
    Paint()..color = Colors.white.withValues(alpha: 0.18),
  );
  canvas.drawRRect(
    badgeRect,
    Paint()
      ..color = Colors.white.withValues(alpha: 0.42)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2,
  );
  _text(
    canvas,
    badgeLabel,
    pad + badgeW / 2,
    outerPad + 23,
    19,
    Colors.white,
    bold: true,
    center: true,
    maxWidth: badgeW - 16,
  );

  final formattedNum = d.number.trim().isEmpty
      ? '#—'
      : (d.number.trim().startsWith('#')
          ? d.number.trim()
          : '#${d.number.trim()}');
  _text(
    canvas,
    formattedNum,
    pad,
    outerPad + 60,
    27,
    const Color(0xFFFDE047),
    bold: true,
    alignStart: true,
    maxWidth: rightSideMaxW,
  );

  final dtFormatted = _formatVoucherDateTime(d.date);
  _text(
    canvas,
    dtFormatted,
    pad,
    outerPad + 102,
    18,
    Colors.white.withValues(alpha: 0.95),
    bold: true,
    alignStart: true,
    maxWidth: rightSideMaxW,
  );

  canvas.restore(); // انتهاء قص الترويسة

  // إطار خارجي ناعم للبطاقة
  canvas.drawRRect(
    cardRRect,
    Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5,
  );

  var y = outerPad + headerH + 22.0;

  // ===== 2) صف بيانات العميل (Metadata Row) مطابق للصورة المرجعية =====
  final metaBox = RRect.fromRectAndRadius(
    Rect.fromLTWH(pad, y, w - pad * 2, metaH),
    const Radius.circular(14),
  );
  canvas.drawRRect(metaBox, Paint()..color = const Color(0xFFF8FAFC));
  canvas.drawRRect(
    metaBox,
    Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4,
  );

  _text(
    canvas,
    'الحساب / العميل',
    w - pad - 24,
    y + 14,
    19,
    muted,
    bold: true,
    alignEnd: true,
  );
  _text(
    canvas,
    d.accountName,
    w - pad - 24,
    y + 48,
    27,
    ink,
    bold: true,
    alignEnd: true,
    maxWidth: (w - pad * 2) * 0.62,
  );

  final phoneDisplay =
      d.accountPhone.trim().isEmpty ? '—' : d.accountPhone.trim();
  _text(
    canvas,
    'رقم الهاتف',
    pad + 24,
    y + 14,
    19,
    muted,
    bold: true,
    alignStart: true,
  );
  _text(
    canvas,
    phoneDisplay,
    pad + 24,
    y + 50,
    24,
    skyDark,
    bold: true,
    alignStart: true,
    maxWidth: (w - pad * 2) * 0.34,
  );

  y += metaH + 20.0;

  // ===== 3) شبكة المنتصف (المبلغ والتفقيط يميناً + الرصيد بعد العملية يساراً) =====
  const gap = 20.0;
  const totalGridW = w - pad * 2;
  const rightBoxW = totalGridW * 0.54 - gap / 2;
  const leftBoxW = totalGridW * 0.46 - gap / 2;
  const rightBoxX = w - pad - rightBoxW;
  const leftBoxX = pad;

  final isGreenMode = d.isCashSale || !d.isDebit;
  final amtColor = isGreenMode ? green : red;
  final amtBg =
      isGreenMode ? const Color(0xFFF0FDF4) : const Color(0xFFFFF5F5);
  final amtBorder =
      isGreenMode ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5);
  final badgeBg =
      isGreenMode ? const Color(0xFF15803D) : const Color(0xFFBE123C);
  final tafqeetPillBg =
      isGreenMode ? const Color(0xFFDCFCE7) : const Color(0xFFFECDD3);

  final rightBox = RRect.fromRectAndRadius(
    Rect.fromLTWH(rightBoxX, y, rightBoxW, midGridH),
    const Radius.circular(16),
  );
  canvas.drawRRect(rightBox, Paint()..color = amtBg);
  canvas.drawRRect(
    rightBox,
    Paint()
      ..color = amtBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6,
  );

  // شارة «عليه (مدين)» / «له (دائن)» في الزاوية العلوية اليمنى لصندوق المبلغ كما في الصورة
  final statusPillText = d.isCashSale
      ? 'مدفوع نقداً'
      : (d.isDebit ? 'عليه (مدين)' : 'له (دائن)');
  const statusPillW = 128.0;
  const statusPillH = 38.0;
  final statusPillRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(
      rightBoxX + rightBoxW - statusPillW - 16,
      y + 14,
      statusPillW,
      statusPillH,
    ),
    const Radius.circular(10),
  );
  canvas.drawRRect(statusPillRect, Paint()..color = badgeBg);
  _text(
    canvas,
    statusPillText,
    rightBoxX + rightBoxW - 16 - statusPillW / 2,
    y + 19,
    18,
    Colors.white,
    bold: true,
    center: true,
  );

  // المبلغ في المنتصف بحجم متناسق واضح (36px)
  _text(
    canvas,
    '${Fmt.money(d.amount, d.currency.decimal)} ${d.currency.symbol}',
    rightBoxX + rightBoxW / 2,
    y + 38,
    36,
    amtColor,
    bold: true,
    center: true,
    maxWidth: rightBoxW - 280,
  );

  // كبسولة التفقيط في منتصف أسفل صندوق المبلغ
  final tafqeetText = 'فقط ${numberToWords(d.amount)} ${d.currency.name} لا غير';
  final tafqeetW = (rightBoxW - 80).clamp(260.0, rightBoxW - 36);
  final tafqeetBox = RRect.fromRectAndRadius(
    Rect.fromLTWH(
      rightBoxX + (rightBoxW - tafqeetW) / 2,
      y + midGridH - 64,
      tafqeetW,
      44,
    ),
    const Radius.circular(14),
  );
  canvas.drawRRect(tafqeetBox, Paint()..color = tafqeetPillBg);
  _text(
    canvas,
    tafqeetText,
    rightBoxX + rightBoxW / 2,
    y + midGridH - 54,
    19,
    amtColor,
    bold: true,
    center: true,
    maxWidth: tafqeetW - 24,
  );

  // الصندوق الأيسر: الرصيد بعد العملية (#F1F5F9) مطابق للصورة المرجعية
  final leftBox = RRect.fromRectAndRadius(
    Rect.fromLTWH(leftBoxX, y, leftBoxW, midGridH),
    const Radius.circular(16),
  );
  canvas.drawRRect(leftBox, Paint()..color = const Color(0xFFF1F5F9));
  canvas.drawRRect(
    leftBox,
    Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5,
  );

  _text(
    canvas,
    'الرصيد بعد العملية',
    leftBoxX + leftBoxW / 2,
    y + 30,
    22,
    muted,
    bold: true,
    center: true,
  );

  if (d.balanceAfter != null) {
    final b = d.balanceAfter!;
    final isZeroBal = Fmt.isZeroMoney(b);
    if (isZeroBal) {
      _text(
        canvas,
        '0 ${d.currency.symbol} (مسدد)',
        leftBoxX + leftBoxW / 2,
        y + 88,
        28,
        green,
        bold: true,
        center: true,
        maxWidth: leftBoxW - 32,
      );
    } else {
      final isDebitBal = b > 0;
      final balWord = isDebitBal ? 'عليه' : 'له';
      final balPillBg =
          isDebitBal ? const Color(0xFFFECDD3) : const Color(0xFFDCFCE7);
      final balPillFg = isDebitBal ? red : green;
      final balNumStr =
          '${Fmt.money(b.abs(), d.currency.decimal)} ${d.currency.symbol}';

      // رسم قيمة الرصيد وبجانبها يميناً شارة «عليه» / «له» كما في الصورة المرجعية
      const pillW = 68.0;
      const pillH = 36.0;
      const centerGroupX = leftBoxX + leftBoxW / 2;
      final pillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(centerGroupX + 68, y + 92, pillW, pillH),
        const Radius.circular(12),
      );
      canvas.drawRRect(pillRect, Paint()..color = balPillBg);
      _text(
        canvas,
        balWord,
        centerGroupX + 68 + pillW / 2,
        y + 97,
        18,
        balPillFg,
        bold: true,
        center: true,
      );
      _text(
        canvas,
        balNumStr,
        centerGroupX + 54,
        y + 88,
        30,
        ink,
        bold: true,
        alignEnd: true,
        maxWidth: leftBoxW - 120,
      );
    }
  } else {
    _text(
      canvas,
      d.isCashSale ? 'مبيعات نقدية (مسددة)' : '—',
      leftBoxX + leftBoxW / 2,
      y + 88,
      25,
      ink,
      bold: true,
      center: true,
      maxWidth: leftBoxW - 32,
    );
  }

  y += midGridH + 20.0;

  // ===== 4) قسم البيان: إما شريط البيان الموحد أو جدول المنتجات المتمدد في فواتير المبيعات =====
  if (d.items.isEmpty) {
    // شريط البيان للسندات العادية (مطابق للصورة المرجعية)
    final statementBox = RRect.fromRectAndRadius(
      Rect.fromLTWH(pad, y, w - pad * 2, singleStatementH),
      const Radius.circular(14),
    );
    canvas.drawRRect(statementBox, Paint()..color = const Color(0xFFEDF2F7));
    canvas.drawRRect(
      statementBox,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    _text(
      canvas,
      'البيان: $fullStatement',
      w / 2,
      y + 16,
      23,
      const Color(0xFF334155),
      bold: true,
      center: true,
      maxWidth: w - pad * 2 - 40,
    );
    y += singleStatementH;
  } else {
    // في فواتير المبيعات/المرتجعات: يظهر البيان والأصناف داخل جدول واضح متناسب العرض والارتفاع
    const tw = w - pad * 2;
    final tableOuter = RRect.fromRectAndRadius(
      Rect.fromLTWH(pad, y, tw, statementSectionH),
      const Radius.circular(14),
    );
    canvas.drawRRect(tableOuter, Paint()..color = Colors.white);

    canvas.save();
    canvas.clipRRect(tableOuter);

    // 4.أ) شريط عنوان البيان أعلى الجدول باللون السماوي الفاتح
    canvas.drawRect(
      Rect.fromLTWH(pad, y, tw, tableTitleH),
      Paint()..color = const Color(0xFFE0F2FE),
    );
    _text(
      canvas,
      'البيان (تفاصيل الأصناف): $fullStatement',
      w - pad - 20,
      y + 10,
      20,
      const Color(0xFF0369A1),
      bold: true,
      alignEnd: true,
      maxWidth: tw * 0.72,
    );
    _text(
      canvas,
      'عدد الأصناف: ${d.items.length}',
      pad + 20,
      y + 10,
      19,
      const Color(0xFF0369A1),
      bold: true,
      alignStart: true,
    );
    y += tableTitleH;

    // إحداثيات أعمدة الجدول (من اليمين لليسار: م | الصنف | الكمية | السعر | الإجمالي)
    const colIdxW = tw * 0.08;
    const colNameW = tw * 0.44;
    const colQtyW = tw * 0.14;
    const colPriceW = tw * 0.17;
    const colTotalW = tw * 0.17;

    const xRight = w - pad;
    const xAfterIdx = xRight - colIdxW;
    const xAfterName = xAfterIdx - colNameW;
    const xAfterQty = xAfterName - colQtyW;
    const xAfterPrice = xAfterQty - colPriceW;

    // 4.ب) ترويسة أعمدة الجدول باللون السماوي الجذاب
    canvas.drawRect(
      Rect.fromLTWH(pad, y, tw, tableHeaderH),
      Paint()..color = skyDark,
    );
    _text(
      canvas,
      'م',
      xRight - colIdxW / 2,
      y + 10,
      19,
      Colors.white,
      bold: true,
      center: true,
    );
    _text(
      canvas,
      'الصنف / المنتج',
      xAfterIdx - 16,
      y + 10,
      19,
      Colors.white,
      bold: true,
      alignEnd: true,
    );
    _text(
      canvas,
      'الكمية',
      xAfterName - colQtyW / 2,
      y + 10,
      19,
      Colors.white,
      bold: true,
      center: true,
    );
    _text(
      canvas,
      'سعر الوحدة',
      xAfterQty - colPriceW / 2,
      y + 10,
      19,
      Colors.white,
      bold: true,
      center: true,
    );
    _text(
      canvas,
      'الإجمالي',
      xAfterPrice - colTotalW / 2,
      y + 10,
      19,
      Colors.white,
      bold: true,
      center: true,
    );
    y += tableHeaderH;

    // 4.ج) صفوف الأصناف بالتناوب مع خطوط شبكة جدول واضحة
    final rowsStartY = y;
    for (var i = 0; i < d.items.length; i++) {
      final it = d.items[i];
      final rowBg = i.isEven ? Colors.white : const Color(0xFFF8FAFC);
      canvas.drawRect(
        Rect.fromLTWH(pad, y, tw, tableRowH),
        Paint()..color = rowBg,
      );
      // خط أفقي فاصل بين الصفوف
      canvas.drawRect(
        Rect.fromLTWH(pad, y + tableRowH - 1, tw, 1),
        Paint()..color = const Color(0xFFE2E8F0),
      );

      _text(
        canvas,
        '${i + 1}',
        xRight - colIdxW / 2,
        y + 10,
        19,
        muted,
        bold: true,
        center: true,
      );
      _text(
        canvas,
        it.name,
        xAfterIdx - 16,
        y + 10,
        20,
        ink,
        bold: true,
        alignEnd: true,
        maxWidth: colNameW - 28,
      );
      _text(
        canvas,
        _quantity(it.quantity),
        xAfterName - colQtyW / 2,
        y + 10,
        20,
        ink,
        bold: true,
        center: true,
      );
      _text(
        canvas,
        Fmt.money(it.unitPrice, d.currency.decimal),
        xAfterQty - colPriceW / 2,
        y + 10,
        20,
        ink,
        center: true,
      );
      _text(
        canvas,
        Fmt.money(it.total, d.currency.decimal),
        xAfterPrice - colTotalW / 2,
        y + 10,
        20,
        skyDark,
        bold: true,
        center: true,
      );
      y += tableRowH;
    }

    // خطوط الأعمدة الرأسية لضمان وضوح الجدول
    final gridPaint = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = 1.2;
    for (final cx in [xAfterIdx, xAfterName, xAfterQty, xAfterPrice]) {
      canvas.drawLine(
        Offset(cx, rowsStartY - tableHeaderH),
        Offset(cx, y),
        gridPaint,
      );
    }

    // 4.د) شريط إجمالي الجدول السفلي
    final itemsTotal =
        d.items.fold<double>(0, (sum, line) => sum + line.total);
    canvas.drawRect(
      Rect.fromLTWH(pad, y, tw, tableFooterH),
      Paint()..color = const Color(0xFFF1F5F9),
    );
    _text(
      canvas,
      'إجمالي قيمة الأصناف',
      w - pad - 20,
      y + 12,
      21,
      ink,
      bold: true,
      alignEnd: true,
    );
    _text(
      canvas,
      '${Fmt.money(itemsTotal, d.currency.decimal)} ${d.currency.symbol}',
      pad + 24,
      y + 10,
      23,
      skyDark,
      bold: true,
      alignStart: true,
    );
    y += tableFooterH;

    canvas.restore();
    canvas.drawRRect(
      tableOuter,
      Paint()
        ..color = const Color(0xFF94A3B8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  // شريط المدفوع والمتبقي في حال البيع الجزئي
  if (hasPartialBar) {
    y += 14.0;
    final pBox = RRect.fromRectAndRadius(
      Rect.fromLTWH(pad, y, w - pad * 2, partialBarH),
      const Radius.circular(12),
    );
    canvas.drawRRect(pBox, Paint()..color = const Color(0xFFFFFBEB));
    canvas.drawRRect(
      pBox,
      Paint()
        ..color = const Color(0xFFFDE68A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    if (paidVal != null && paidVal.isNotEmpty) {
      _text(
        canvas,
        'المبلغ المدفوع مقدماً: $paidVal',
        w - pad - 20,
        y + 14,
        20,
        green,
        bold: true,
        alignEnd: true,
      );
    }
    if (remainVal != null && remainVal.isNotEmpty) {
      _text(
        canvas,
        'المبلغ المتبقي (آجل): $remainVal',
        pad + 20,
        y + 14,
        20,
        red,
        bold: true,
        alignStart: true,
      );
    }
    y += partialBarH;
  }

  y += 24.0;

  // ===== 5) الخط المنقط وشريط التذييل السفلي (Footer Bar) مطابق للصورة المرجعية =====
  final dashPaint = Paint()
    ..color = const Color(0xFFCBD5E1)
    ..strokeWidth = 1.8;
  var dashX = pad;
  while (dashX < w - pad) {
    canvas.drawLine(
      Offset(dashX, y),
      Offset((dashX + 9.0).clamp(pad, w - pad), y),
      dashPaint,
    );
    dashX += 16.0;
  }

  final sellerIdentity =
      d.sellerOrDevice.trim().isEmpty ? 'المدير' : d.sellerOrDevice.trim();
  final userLabel = 'المستخدم: $sellerIdentity';

  // كبسولة اسم المستخدم في أقصى اليمين كما في الصورة المرجعية
  final userTp = TextPainter(
    text: TextSpan(
      text: userLabel,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        fontFamily: uiFontFamily,
      ),
    ),
    textDirection: TextDirection.rtl,
  )..layout();
  final userPillW = userTp.width + 32.0;
  const userPillH = 42.0;
  final userPillRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(w - pad - userPillW, y + 16, userPillW, userPillH),
    const Radius.circular(10),
  );
  canvas.drawRRect(userPillRect, Paint()..color = const Color(0xFFF1F5F9));
  _text(
    canvas,
    userLabel,
    w - pad - userPillW / 2,
    y + 23,
    20,
    ink,
    bold: true,
    center: true,
  );

  // فاصل عمودي وعبارة «شكراً لتعاملكم معنا» باللون السماوي الجذاب
  _text(
    canvas,
    '|   شكراً لتعاملكم معنا',
    w - pad - userPillW - 14,
    y + 23,
    20,
    skyBright,
    bold: true,
    alignEnd: true,
  );

  final leftFooterNote = d.footer.trim().isEmpty
      ? 'سند آلي لا يحتاج إلى ختم أو توقيع'
      : d.footer.trim();
  _text(
    canvas,
    leftFooterNote,
    pad,
    y + 23,
    20,
    muted,
    bold: true,
    alignStart: true,
    maxWidth: w * 0.36,
  );

  final picture = recorder.endRecording();
  final img = await picture.toImage(w.toInt(), height.ceil());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  final data = bytes!.buffer.asUint8List();

  final dir = await getTemporaryDirectory();
  final shared = Directory('${dir.path}/receipts')..createSync(recursive: true);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final file = File('${shared.path}/receipt-$stamp.png');
  await file.writeAsBytes(data, flush: true);
  return file.path;
}

String _formatVoucherDateTime(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  var h = dt.hour;
  final period = h >= 12 ? 'PM' : 'AM';
  h = h % 12;
  if (h == 0) h = 12;
  final hh = h.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y/$m/$d • $hh:$mm $period';
}

String _quantity(double value) =>
    value == value.roundToDouble() ? Fmt.money(value) : Fmt.money(value, 2);

void _text(
  Canvas canvas,
  String text,
  double x,
  double y,
  double size,
  Color color, {
  bool bold = false,
  bool center = false,
  bool alignEnd = false,
  bool alignStart = false,
  double? maxWidth,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
        fontFamily: uiFontFamily,
        height: 1.35,
      ),
    ),
    textDirection: TextDirection.rtl,
    textAlign: center ? TextAlign.center : TextAlign.right,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth ?? 800);

  final dx = center
      ? x - tp.width / 2
      : (alignEnd ? x - tp.width : (alignStart ? x : x - tp.width / 2));
  tp.paint(canvas, Offset(dx, y));
}

/// يحوّل بايتات صورة إلى ملف دائم داخل مجلد مستندات التطبيق.
/// يُستخدم للصور المختارة ولشعار المؤسسة حتى تبقى المسارات صالحة بعد إعادة التشغيل.
Future<String> saveImageBytes(Uint8List bytes, {String prefix = 'img'}) async {
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/images')..createSync(recursive: true);
  final f = File(
    '${folder.path}/$prefix-${DateTime.now().millisecondsSinceEpoch}.png',
  );
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}
