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
    final shortDev = rawDevId.replaceFirst('DEVICE-', '').trim();
    final devCode = shortDev.length >= 4 ? shortDev.substring(0, 4) : shortDev;
    if (c.isNotEmpty && devCode.isNotEmpty && !c.contains(devCode)) {
      return '$c ($devCode)';
    }
    if (c.isNotEmpty) return c;
    if (devName.isNotEmpty) return devName;
    if (devCode.isNotEmpty) return devCode;
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

/// يرسم الإيصال كصورة PNG ويحفظه في مجلد مؤقت، ثم يعيد مساره.
///
/// نرسم عبر `PictureRecorder` مباشرة بدل التقاط عنصر من الشجرة، فالصورة
/// تُولَّد حتى لو لم تُعرض أي واجهة — وهذا شرط الإرسال التلقائي.
Future<String> buildReceiptImage(ReceiptData d) async {
  const w = 1000.0;
  const pad = 48.0;

  // استخراج المبلغ المدفوع والمتبقي في حال البيع الجزئي
  String? paidVal;
  String? remainVal;
  for (final l in d.notes.split('\n')) {
    final t = l.trim();
    if (t.startsWith('المبلغ المدفوع:')) {
      paidVal = t.substring('المبلغ المدفوع:'.length).trim();
    } else if (t.startsWith('المبلغ المتبقي:')) {
      remainVal = t.substring('المبلغ المتبقي:'.length).trim();
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

  final hasSubHeaderInfo =
      d.orgAddress.trim().isNotEmpty || d.orgPhone.trim().isNotEmpty;
  final headerH = (logo != null ? 214.0 : 138.0) + (hasSubHeaderInfo ? 28.0 : 0.0);
  const bandH = 66.0;
  const rowH = 58.0;
  const amountH = 128.0;
  final infoRows = 1 + // اسم الحساب
      (d.accountPhone.isNotEmpty ? 1 : 0) +
      1; // التاريخ والوقت (يُرسم لاحقاً في قسم التفاصيل)
  final partialRows =
      (paidVal != null && paidVal.isNotEmpty ? 1 : 0) +
      (remainVal != null && remainVal.isNotEmpty ? 1 : (d.isCashSale ? 1 : 0));
  final showStatement = d.statement.isNotEmpty &&
      !(d.items.isNotEmpty && d.statement.contains('فاتورة'));
  final detailRows = (showStatement ? 1 : 0) + partialRows + 1;
  final itemsBlock =
      d.items.isEmpty ? 0.0 : (54.0 + d.items.length * 52.0 + 56.0 + 24.0);
  final balanceBlock = d.balanceAfter != null ? 96.0 : 0.0;
  final height = headerH +
      bandH +
      (infoRows - 1) * rowH + // صفوف بيانات الحساب (بدون صف التاريخ)
      24 +
      amountH +
      24 +
      itemsBlock +
      detailRows * rowH +
      16 +
      balanceBlock +
      148 + // تذييل الموظف/الجهاز + الشكر
      40;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, height));

  const ink = Color(0xFF1F2A37); // نص أساسي داكن
  const muted = Color(0xFF6B7280); // عناوين رمادية
  const line = Color(0xFFE5E7EB); // خطوط فاصلة
  const green = Color(0xFF15803D); // أخضر «له»/الترويسة
  const red = Color(0xFFDC2626); // أحمر «عليه»

  canvas.drawRect(Rect.fromLTWH(0, 0, w, height), Paint()..color = Colors.white);

  // ===== 1) الترويسة: توسيط الشعار أعلى المنتصف + اسم المنشأة تحته + العنوان والهاتف =====
  canvas.drawRect(
      Rect.fromLTWH(0, 0, w, headerH), Paint()..color = green);
  var headerY = 18.0;
  if (logo != null) {
    final logoBox = RRect.fromRectAndRadius(
      Rect.fromLTWH((w - 88) / 2, headerY, 88, 88),
      const Radius.circular(18),
    );
    canvas.drawRRect(logoBox, Paint()..color = Colors.white);
    canvas.drawImageRect(
      logo,
      Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      logoBox.outerRect.deflate(6),
      Paint()..filterQuality = ui.FilterQuality.high,
    );
    headerY += 98.0;
  } else {
    headerY = 26.0;
  }
  _text(
    canvas,
    d.orgName.isEmpty ? 'سجل الحسابات' : d.orgName,
    w / 2,
    headerY,
    36,
    Colors.white,
    bold: true,
    center: true,
    maxWidth: w - pad * 2,
  );
  headerY += 50.0;
  if (hasSubHeaderInfo) {
    final parts = <String>[
      if (d.orgAddress.trim().isNotEmpty) '📍 ${d.orgAddress.trim()}',
      if (d.orgPhone.trim().isNotEmpty) '📞 ${d.orgPhone.trim()}',
    ];
    _text(
      canvas,
      parts.join('  •  '),
      w / 2,
      headerY,
      23,
      Colors.white.withValues(alpha: 0.92),
      center: true,
      maxWidth: w - pad * 2,
    );
  }

  var y = headerH;

  // ===== 2) شريط «سند عملية / فاتورة» + الرقم المرجعي مع بادئة الجهاز يساراً =====
  canvas.drawRect(
      Rect.fromLTWH(0, y, w, bandH), Paint()..color = const Color(0xFFF3F4F6));
  _text(canvas, d.title, w - pad, y + 16, 28, ink,
      bold: true, alignEnd: true);
  if (d.number.isNotEmpty) {
    final formattedNum =
        d.number.startsWith('#') ? d.number : '#${d.number}';
    _text(canvas, formattedNum, pad, y + 18, 24, muted,
        bold: true, alignStart: true);
  }
  y += bandH + 18;

  void divider() {
    canvas.drawRect(
        Rect.fromLTWH(pad, y, w - pad * 2, 2), Paint()..color = line);
    y += 16;
  }

  // صف بيانات: عنوان يميناً وقيمة في الوسط/يسار (مثل «تدوين الحسابات»).
  void infoRow(String label, String value, {Color? valueColor, bool big = false}) {
    _text(canvas, label, w - pad, y, 24, muted, alignEnd: true);
    _text(canvas, value, pad, y - (big ? 4 : 0), big ? 28 : 25,
        valueColor ?? ink,
        bold: true, alignStart: true, maxWidth: w * .6);
    y += rowH;
  }

  // ===== 3) بيانات الحساب =====
  infoRow('اسم الحساب', d.accountName);
  if (d.accountPhone.isNotEmpty) infoRow('رقم الهاتف', d.accountPhone);
  divider();

  // ===== 4) كبسولة المبلغ الكبيرة: «مدفوع نقداً» أو «عليه» أحمر / «له» أخضر =====
  final amtColor = d.isCashSale ? green : (d.isDebit ? red : green);
  final amtBg = d.isCashSale
      ? const Color(0xFFEAF7EF)
      : (d.isDebit ? const Color(0xFFFDECEC) : const Color(0xFFEAF7EF));
  final amountBox = RRect.fromRectAndRadius(
    Rect.fromLTWH(pad, y, w - pad * 2, amountH),
    const Radius.circular(22),
  );
  canvas.drawRRect(amountBox, Paint()..color = amtBg);
  _text(
    canvas,
    d.isCashSale ? 'مدفوع نقداً' : (d.isDebit ? 'عليه' : 'له'),
    w - pad - 28,
    y + 42,
    d.isCashSale ? 26 : 30,
    amtColor,
    bold: true,
    alignEnd: true,
  );
  _text(
    canvas,
    '${Fmt.money(d.amount, d.currency.decimal)} ${d.currency.symbol}',
    pad + (w - pad * 2) / 2 - 40,
    y + 26,
    54,
    amtColor,
    bold: true,
    center: true,
  );
  _text(
    canvas,
    'فقط ${numberToWords(d.amount)} ${d.currency.name} لا غير',
    w / 2,
    y + amountH - 36,
    18,
    muted,
    center: true,
    maxWidth: w - pad * 3,
  );
  y += amountH + 24;

  // ===== 5) جدول الأصناف (صنف/كمية/سعر/إجمالي) مثل سند نكسورا =====
  if (d.items.isNotEmpty) {
    const tPad = pad;
    const tw = w - tPad * 2;
    // أعمدة من اليمين: الصنف 40٪، الكمية 15٪، السعر 22.5٪، الإجمالي 22.5٪.
    const cName = w - tPad; // حافة يمنى
    const cQty = w - tPad - tw * 0.40 - tw * 0.075;
    const cPrice = tPad + tw * 0.225 + tw * 0.1125;
    const cTotal = tPad + tw * 0.1125;
    // رأس الجدول.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(tPad, y, tw, 46), const Radius.circular(10)),
      Paint()..color = const Color(0xFFF3F4F6),
    );
    _text(canvas, 'الصنف', cName - 14, y + 8, 22, muted, alignEnd: true);
    _text(canvas, 'الكمية', cQty, y + 8, 22, muted, center: true);
    _text(canvas, 'السعر', cPrice, y + 8, 22, muted, center: true);
    _text(canvas, 'الإجمالي', cTotal, y + 8, 22, muted, center: true);
    y += 54;
    for (final it in d.items) {
      _text(canvas, it.name, cName - 14, y, 23, ink,
          bold: true, alignEnd: true, maxWidth: tw * 0.38);
      _text(canvas, _quantity(it.quantity), cQty, y, 23, ink, center: true);
      _text(canvas, Fmt.money(it.unitPrice, d.currency.decimal), cPrice, y, 23,
          ink, center: true);
      _text(canvas, Fmt.money(it.total, d.currency.decimal), cTotal, y, 23,
          ink, bold: true, center: true);
      y += 52;
    }
    // صف الإجمالي.
    final itemsTotal =
        d.items.fold<double>(0, (sum, line) => sum + line.total);
    canvas.drawRect(
        Rect.fromLTWH(tPad, y, tw, 2), Paint()..color = line);
    y += 12;
    _text(canvas, 'الإجمالي', w - tPad - 14, y, 24, ink,
        bold: true, alignEnd: true);
    _text(canvas,
        '${Fmt.money(itemsTotal, d.currency.decimal)} ${d.currency.symbol}',
        tPad + 14, y, 26, ink, bold: true, alignStart: true);
    y += 56;
    divider();
  }

  // ===== 6) التفاصيل + المدفوع والمتبقي (إن وُجد) + التاريخ والوقت =====
  if (paidVal != null && paidVal.isNotEmpty) {
    infoRow('المبلغ المدفوع مقدماً', paidVal, valueColor: green, big: true);
  }
  if (remainVal != null && remainVal.isNotEmpty) {
    infoRow('المبلغ المتبقي (آجل)', remainVal, valueColor: red, big: true);
  } else if (d.isCashSale) {
    infoRow(
      'المتبقي',
      '${Fmt.money(0, d.currency.decimal)} ${d.currency.symbol}',
      valueColor: green,
      big: true,
    );
  }
  if (showStatement) infoRow('التفاصيل', d.statement);
  infoRow('التاريخ والوقت', Fmt.dateTime(d.date));
  y += 4;

  // ===== 7) الرصيد بعد العملية (شريط رمادي فاتح بقيمة ملونة) =====
  if (d.balanceAfter != null) {
    final b = d.balanceAfter!;
    final label = b > 0 ? '(عليه)' : (b < 0 ? '(له)' : '');
    final balColor = b > 0 ? red : (b < 0 ? green : ink);
    final balBox = RRect.fromRectAndRadius(
      Rect.fromLTWH(pad, y, w - pad * 2, 76),
      const Radius.circular(16),
    );
    canvas.drawRRect(balBox, Paint()..color = const Color(0xFFF3F4F6));
    _text(canvas, 'الرصيد بعد العملية', w - pad - 22, y + 22, 25, ink,
        bold: true, alignEnd: true);
    _text(
      canvas,
      '${Fmt.money(b.abs(), d.currency.decimal)} ${d.currency.symbol} $label',
      pad + 22,
      y + 20,
      27,
      balColor,
      bold: true,
      alignStart: true,
    );
    y += 96;
  }

  // ===== 8) التذييل الرسمي: هوية البائع / الجهاز + رسالة الشكر =====
  canvas.drawRect(
      Rect.fromLTWH(pad, y, w - pad * 2, 2), Paint()..color = line);
  y += 18;
  final sellerIdentity =
      d.sellerOrDevice.trim().isEmpty ? 'المدير' : d.sellerOrDevice.trim();
  _text(
    canvas,
    'الموظف / الجهاز: $sellerIdentity',
    w / 2,
    y,
    21,
    ink,
    bold: true,
    center: true,
    maxWidth: w - pad * 2,
  );
  y += 36;
  _text(
    canvas,
    'شكراً لتعاملكم معنا — نتمنى لكم أطيب الأوقات',
    w / 2,
    y,
    22,
    green,
    bold: true,
    center: true,
  );
  y += 38;
  _text(
    canvas,
    d.footer.isEmpty ? 'هذا السند آلي ولا يحتاج إلى ختم أو توقيع.' : d.footer,
    w / 2,
    y,
    18,
    muted,
    center: true,
    maxWidth: w - pad * 2,
  );

  final picture = recorder.endRecording();
  final img = await picture.toImage(w.toInt(), height.toInt());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  final data = bytes!.buffer.asUint8List();

  final dir = await getTemporaryDirectory();
  final shared = Directory('${dir.path}/receipts')..createSync(recursive: true);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final file = File('${shared.path}/receipt-$stamp.png');
  await file.writeAsBytes(data, flush: true);
  return file.path;
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
    maxLines: 3,
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
