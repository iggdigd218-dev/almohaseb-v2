// مستند فاتورة البيع الحرارية (80مم) — وحدة مستقلة قابلة للاختبار.
//
// كانت تبنيتها داخل `pos_screen._printThermalInvoice` بـ `pw.Document()` **بلا
// أي خط**، فكانت كل فواتير البيع تخرج مربعات «▯»: الخط الافتراضي Helvetica لا
// يحمل حرفاً عربياً واحداً. نُقلت إلى هنا لسببين:
//   1. تطبيق خدمة الخطوط العربية (PdfFonts) واتجاه RTL على كل فاتورة.
//   2. إتاحة بناء المستند للاختبار الآلي (بند «اختبار إنشاء المعاينة»).
library;

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'accounting.dart';
import 'format.dart';
import 'models.dart';
import 'pdf_fonts.dart';
import '../data/sync/subscription_guard.dart' show kWatermarkText;

/// نتيجة بناء الفاتورة: المستند (للفحص) والبايتات (للطباعة/المشاركة).
class ThermalInvoiceDoc {
  const ThermalInvoiceDoc(this.document, this.bytes);

  final pw.Document document;

  /// بايتات PDF جاهزة للطباعة أو الحفظ أو المشاركة.
  final Uint8List bytes;
}

/// يرسم إشارة السهم الصاعد المنحني/المتعرج المستوحى من أيقونة التطبيق
/// باللون الأسود الصافي (`PdfColors.black`) بدون خلفية أو إطار، لتوافق
/// الطابعات الحرارية أحادية اللون (Monochrome Thermal Printers).
pw.Widget buildThermalArrowLogo({double size = 44}) {
  return pw.CustomPaint(
    size: PdfPoint(size, size),
    painter: (PdfGraphics canvas, PdfPoint s) {
      final w = s.x;
      final h = s.y;

      canvas
        ..setFillColor(PdfColors.black)
        ..setStrokeColor(PdfColors.black);

      // مسار جذع السهم الصاعد المنحني/المتعرج (أسفل اليسار ← قمة أولى ← انحناءة ← عنق رأس السهم)
      canvas
        ..moveTo(w * 0.14, h * 0.14)
        ..lineTo(w * 0.40, h * 0.56)
        ..lineTo(w * 0.52, h * 0.45)
        ..lineTo(w * 0.70, h * 0.73)
        ..lineTo(w * 0.79, h * 0.65)
        ..lineTo(w * 0.54, h * 0.29)
        ..lineTo(w * 0.43, h * 0.40)
        ..lineTo(w * 0.27, h * 0.14)
        ..closePath()
        ..fillPath();

      // رأس السهم المثلثي المفرغ من الوسط (مطابق لهوية أيقونة التطبيق) باللون الأسود الصافي
      canvas
        ..setLineWidth(w * 0.085)
        ..setLineJoin(PdfLineJoin.miter)
        ..moveTo(w * 0.63, h * 0.75)
        ..lineTo(w * 0.87, h * 0.87)
        ..lineTo(w * 0.86, h * 0.59)
        ..closePath()
        ..strokePath();
    },
  );
}

String _thermalQty(double q) {
  if (q == q.truncateToDouble()) {
    return q.toInt().toString();
  }
  return Fmt.money(q, 2);
}

String _resolveThermalCurrencySymbol(String rawCodeOrSymbol, String? explicitSymbol) {
  if (explicitSymbol != null && explicitSymbol.trim().isNotEmpty) {
    return PdfFonts.sanitize(explicitSymbol.trim());
  }
  final clean = rawCodeOrSymbol.trim();
  if (clean.isEmpty) return 'محلي';
  final upper = clean.toUpperCase();
  for (final c in kDefaultCurrencies) {
    if (c.code.toUpperCase() == upper) {
      return PdfFonts.sanitize(c.symbol);
    }
  }
  for (final c in kPresetCurrencies) {
    if (c.code.toUpperCase() == upper) {
      return PdfFonts.sanitize(c.symbol);
    }
  }
  return PdfFonts.sanitize(clean);
}

pw.Widget _thermalTableCell(
  String text, {
  pw.Font? font,
  double fontSize = 8.0,
  pw.TextAlign align = pw.TextAlign.center,
}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 2.5, vertical: 3),
    child: pw.Text(
      PdfFonts.sanitize(text),
      textAlign: align,
      style: pw.TextStyle(
        fontSize: fontSize,
        font: font,
        fontWeight: font != null ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  );
}

/// يبني فاتورة حرارية 80مم بخط عربي مدمج واتجاه من اليمين إلى اليسار.
///
/// * [orgName] اسم المتجر — يظهر على جوانب أعلى الفاتورة الحرارية.
/// * [lines] سطور الأصناف (م، الصنف، الكمية، السعر، الإجمالي).
/// * [stamp] يضيف سطر الختم الصغير أسفل التذييل للحساب المقيد.
Future<ThermalInvoiceDoc> buildThermalInvoiceDocument({
  required Tx tx,
  required Account? account,
  required List<InvoiceLine> lines,
  required String orgName,
  required String orgPhone,
  required String footer,
  String orgAddress = '',
  String sellerOrDevice = '',
  String logoPath = '',
  String logoBase64 = '',
  String? currencySymbol,
  bool stamp = false,
}) async {
  // (بند 2) تحميل الخط العربي قبل إنشاء المستند — مرة واحدة ومخبّأة.
  final fonts = await PdfFonts.load();

  // تطهير كافة الحقول النصية من محارف التحكم وعلامات الاتجاه غير المرئية
  final cleanOrgName = PdfFonts.sanitize(orgName.trim());
  final cleanOrgAddress = PdfFonts.sanitize(orgAddress.trim());
  final cleanOrgPhone = PdfFonts.sanitize(orgPhone.trim());
  final cleanRef = PdfFonts.sanitize(
    tx.reference
        .trim()
        .replaceFirst(RegExp(r'^#+'), '')
        .replaceFirst(RegExp(r'#+$'), '')
        .trim(),
  );
  final currSymbol =
      _resolveThermalCurrencySymbol(tx.currency, currencySymbol);
  final cleanAccountName = PdfFonts.sanitize(tx.resolvedPartyName(account));
  final cleanSeller = PdfFonts.sanitize(sellerOrDevice.trim());
  final rawFooter = PdfFonts.sanitize(footer.trim());
  final cleanFooter = (rawFooter.isEmpty ||
          rawFooter.contains('شكراً لتعاملكم') ||
          rawFooter.contains('شكراً لزيارتكم'))
      ? 'سند آلي لا يحتاج إلى ختم أو توقيع'
      : rawFooter;

  // استخراج تفاصيل البيع الجزئي والخصم إن وُجدت في ملاحظات الفاتورة
  String? paidVal;
  String? remainVal;
  String? discountVal;
  for (final l in tx.notes.split('\n')) {
    final t = l.trim();
    if (t.startsWith('المبلغ المدفوع:')) {
      paidVal = PdfFonts.sanitize(
          t.substring('المبلغ المدفوع:'.length).trim());
    } else if (t.startsWith('المبلغ المتبقي:')) {
      remainVal = PdfFonts.sanitize(
          t.substring('المبلغ المتبقي:'.length).trim());
    } else if (t.startsWith('الخصم:')) {
      discountVal = PdfFonts.sanitize(
          t.substring('الخصم:'.length).trim());
    }
  }

  final itemsTotal = lines.fold<double>(0, (s, it) => s + it.total);
  if ((discountVal == null || discountVal.isEmpty) &&
      lines.isNotEmpty &&
      itemsTotal > tx.amount + 0.009) {
    discountVal = '${Fmt.money(itemsTotal - tx.amount)} $currSymbol';
  }

  final dateStr =
      '${Fmt.date(tx.date)} ${tx.date.hour.toString().padLeft(2, '0')}:${tx.date.minute.toString().padLeft(2, '0')}';

  final doc = pw.Document(
    // (بند 3) تعيين الخط في ثيم المستند: يورّثه لكل النصوص تلقائياً.
    theme: fonts.theme,
  );

  doc.addPage(
    pw.Page(
      pageTheme: pw.PageTheme(
        pageFormat: const PdfPageFormat(
          80 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 3.5 * PdfPageFormat.mm,
        ),
        // (بند 4) اتجاه RTL على مستوى الصفحة: يضبط ترتيب الأحرف والأرقام
        // واتجاه الأعمدة في كل سطر، وليس فقط محاذاة النص.
        textDirection: pw.TextDirection.rtl,
        theme: fonts.theme,
      ),
      build: (pw.Context context) {
        return PdfFonts.rtl(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // 1) ترويسة الفاتورة الحرارية: شعار وهوية النظام في المنتصف، وبيانات المنشأة موزعة على الجوانب
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  // الجانب الأيمن: اسم المنشأة وعنوانها
                  pw.Expanded(
                    flex: 3,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (cleanOrgName.isNotEmpty)
                          pw.Text(
                            cleanOrgName,
                            style: pw.TextStyle(
                              fontSize: 9.5,
                              font: fonts.bold,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                        if (cleanOrgAddress.isNotEmpty)
                          pw.Text(
                            cleanOrgAddress,
                            style: const pw.TextStyle(fontSize: 7.5),
                          ),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 4),
                  // الوسط تماماً: أيقونة السهم الأسود + المحاسب - Al-Mohaseb + هاتف: +967774190040
                  pw.Expanded(
                    flex: 4,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        buildThermalArrowLogo(size: 28),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          'المحاسب - Al-Mohaseb',
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(
                            fontSize: 8.5,
                            font: fonts.bold,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.center,
                          mainAxisSize: pw.MainAxisSize.min,
                          children: [
                            pw.Text(
                              'هاتف: ',
                              style: const pw.TextStyle(fontSize: 7.5),
                            ),
                            pw.Directionality(
                              textDirection: pw.TextDirection.ltr,
                              child: pw.Text(
                                '+967774190040',
                                style: const pw.TextStyle(fontSize: 7.5),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 4),
                  // الجانب الأيسر: هاتف المنشأة والتاريخ
                  pw.Expanded(
                    flex: 3,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        if (cleanOrgPhone.isNotEmpty)
                          pw.Directionality(
                            textDirection: pw.TextDirection.ltr,
                            child: pw.Text(
                              cleanOrgPhone,
                              style: pw.TextStyle(
                                fontSize: 8,
                                font: fonts.bold,
                              ),
                            ),
                          ),
                        pw.Text(
                          dateStr,
                          textAlign: pw.TextAlign.left,
                          style: const pw.TextStyle(fontSize: 7),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Divider(thickness: 0.8),
              // 2) نوع الفاتورة والرقم المرجعي (بدون تكرار (مدفوع نقداً) وبدون #)
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    PdfFonts.sanitize(
                      tx.type == OpType.revenue
                          ? 'فاتورة نقدية مدفوعة'
                          : 'فاتورة مبيعات',
                    ),
                    style: pw.TextStyle(
                      fontSize: 9,
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (cleanRef.isNotEmpty)
                    pw.Directionality(
                      textDirection: pw.TextDirection.ltr,
                      child: pw.Text(
                        cleanRef,
                        style: pw.TextStyle(
                          fontSize: 9,
                          font: fonts.bold,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              if (cleanAccountName.isNotEmpty)
                pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(
                    'العميل: $cleanAccountName',
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                ),
              pw.SizedBox(height: 3),
              // 3) جدول المبيعات الفعلي المقسم بأعمدة (م، الصنف، الكمية، السعر، الإجمالي)
              if (lines.isNotEmpty)
                pw.Table(
                  border: pw.TableBorder.all(
                    color: PdfColors.grey700,
                    width: 0.5,
                  ),
                  columnWidths: const {
                    0: pw.FlexColumnWidth(1.6), // الإجمالي (أقصى اليسار في RTL)
                    1: pw.FlexColumnWidth(1.5), // السعر
                    2: pw.FlexColumnWidth(1.1), // الكمية
                    3: pw.FlexColumnWidth(3.2), // الصنف
                    4: pw.FlexColumnWidth(0.7), // م (أقصى اليمين في RTL)
                  },
                  children: [
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(
                        color: PdfColors.grey200,
                      ),
                      children: [
                        _thermalTableCell('الإجمالي', font: fonts.bold, fontSize: 8),
                        _thermalTableCell('السعر', font: fonts.bold, fontSize: 8),
                        _thermalTableCell('الكمية', font: fonts.bold, fontSize: 8),
                        _thermalTableCell('الصنف', font: fonts.bold, fontSize: 8),
                        _thermalTableCell('م', font: fonts.bold, fontSize: 8),
                      ],
                    ),
                    for (var i = 0; i < lines.length; i++)
                      pw.TableRow(
                        children: [
                          _thermalTableCell(
                            Fmt.money(lines[i].total),
                            font: fonts.bold,
                            fontSize: 8,
                          ),
                          _thermalTableCell(
                            Fmt.money(lines[i].unitPrice),
                            fontSize: 8,
                          ),
                          _thermalTableCell(
                            _thermalQty(lines[i].quantity),
                            fontSize: 8,
                          ),
                          _thermalTableCell(
                            lines[i].name,
                            fontSize: 8,
                            align: pw.TextAlign.right,
                          ),
                          _thermalTableCell(
                            '${i + 1}',
                            fontSize: 7.5,
                          ),
                        ],
                      ),
                  ],
                ),
              pw.SizedBox(height: 4),
              // 4) قسم الإجماليات والخصم بعملة المنشأة المعتمدة
              if (discountVal != null && discountVal.isNotEmpty) ...[
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'إجمالي قيمة الأصناف:',
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                    pw.Text(
                      '${Fmt.money(itemsTotal)} $currSymbol',
                      style: pw.TextStyle(
                        fontSize: 8.5,
                        font: fonts.bold,
                      ),
                    ),
                  ],
                ),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'الخصم:',
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                    pw.Text(
                      discountVal.contains(currSymbol)
                          ? discountVal
                          : '$discountVal $currSymbol',
                      style: pw.TextStyle(
                        fontSize: 8.5,
                        font: fonts.bold,
                      ),
                    ),
                  ],
                ),
              ],
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'الإجمالي المطلوب:',
                    style: pw.TextStyle(
                      fontSize: 9.5,
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    '${Fmt.money(tx.amount)} $currSymbol',
                    style: pw.TextStyle(
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
              if (paidVal != null && paidVal.isNotEmpty) ...[
                pw.SizedBox(height: 2),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      PdfFonts.sanitize('المبلغ المدفوع مقدماً:'),
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                    pw.Text(
                      paidVal.replaceAll('YER', currSymbol),
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontSize: 8.5,
                      ),
                    ),
                  ],
                ),
              ],
              if (remainVal != null && remainVal.isNotEmpty) ...[
                pw.SizedBox(height: 2),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'المبلغ المتبقي (آجل):',
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                    pw.Text(
                      remainVal.replaceAll('YER', currSymbol),
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontSize: 8.5,
                      ),
                    ),
                  ],
                ),
              ] else if (tx.type == OpType.revenue) ...[
                pw.SizedBox(height: 2),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'المتبقي:',
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                    pw.Text(
                      '0 $currSymbol',
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontSize: 8.5,
                      ),
                    ),
                  ],
                ),
              ],
              pw.SizedBox(height: 4),
              pw.Divider(thickness: 0.5),
              // 5) التذييل النظيف (بدون رقم هاتف مكرر وبدون عبارة الشكر)
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  if (cleanSeller.isNotEmpty)
                    pw.Text(
                      'الموظف: $cleanSeller',
                      style: pw.TextStyle(
                        fontSize: 8,
                        font: fonts.bold,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  pw.Expanded(
                    child: pw.Text(
                      cleanFooter,
                      style: const pw.TextStyle(fontSize: 7.5),
                      textAlign: cleanSeller.isNotEmpty
                          ? pw.TextAlign.left
                          : pw.TextAlign.center,
                    ),
                  ),
                ],
              ),
              if (stamp) ...[
                pw.SizedBox(height: 3),
                pw.Text(
                  PdfFonts.sanitize(kWatermarkText),
                  style: const pw.TextStyle(
                    fontSize: 6.5,
                    color: PdfColors.grey600,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
              ],
            ],
          ),
        );
      },
    ),
  );

  return ThermalInvoiceDoc(doc, await doc.save());
}

/// بايتات PDF لفاتورة حرارية جاهزة للطباعة/المشاركة.
Future<Uint8List> buildThermalInvoicePdf({
  required Tx tx,
  required Account? account,
  required List<InvoiceLine> lines,
  required String orgName,
  required String orgPhone,
  required String footer,
  String orgAddress = '',
  String sellerOrDevice = '',
  String logoPath = '',
  String logoBase64 = '',
  String? currencySymbol,
  bool stamp = false,
}) async =>
    (await buildThermalInvoiceDocument(
      tx: tx,
      account: account,
      lines: lines,
      orgName: orgName,
      orgPhone: orgPhone,
      footer: footer,
      orgAddress: orgAddress,
      sellerOrDevice: sellerOrDevice,
      logoPath: logoPath,
      logoBase64: logoBase64,
      currencySymbol: currencySymbol,
      stamp: stamp,
    ))
        .bytes;
