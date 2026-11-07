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

/// يبني فاتورة حرارية 80مم بخط عربي مدمج واتجاه من اليمين إلى اليسار.
///
/// * [orgName] اسم المتجر — يظهر بالخط العريض في رأس الفاتورة.
/// * [lines] سطور الأصناف (الاسم والكمية وسعر الوحدة والإجمالي).
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
  bool stamp = false,
}) async {
  // (بند 2) تحميل الخط العربي قبل إنشاء المستند — مرة واحدة ومخبّأة.
  final fonts = await PdfFonts.load();

  // تطهير كافة الحقول النصية من محارف التحكم وعلامات الاتجاه غير المرئية
  final cleanOrgName = PdfFonts.sanitize(orgName.trim());
  final cleanOrgAddress = PdfFonts.sanitize(orgAddress.trim());
  final cleanOrgPhone = PdfFonts.sanitize(orgPhone.trim());
  final cleanRef = PdfFonts.sanitize(tx.reference.trim());
  final cleanCurrency = PdfFonts.sanitize(tx.currency.trim());
  final cleanAccountName =
      account != null ? PdfFonts.sanitize(account.name.trim()) : '';
  final cleanAccountPhone =
      account != null ? PdfFonts.sanitize(account.phone.trim()) : '';
  final cleanSeller = PdfFonts.sanitize(sellerOrDevice.trim());
  final cleanFooter = PdfFonts.sanitize(footer.trim());

  // استخراج تفاصيل البيع الجزئي إن وُجدت في ملاحظات الفاتورة
  String? paidVal;
  String? remainVal;
  for (final l in tx.notes.split('\n')) {
    final t = l.trim();
    if (t.startsWith('المبلغ المدفوع:')) {
      paidVal = PdfFonts.sanitize(
          t.substring('المبلغ المدفوع:'.length).trim());
    } else if (t.startsWith('المبلغ المتبقي:')) {
      remainVal = PdfFonts.sanitize(
          t.substring('المبلغ المتبقي:'.length).trim());
    }
  }

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
          marginAll: 4 * PdfPageFormat.mm,
        ),
        // (بند 4) اتجاه RTL على مستوى الصفحة: يضبط ترتيب الأحرف والأرقام
        // واتجاه الأعمدة في كل سطر، وليس فقط محاذاة النص.
        textDirection: pw.TextDirection.rtl,
        theme: fonts.theme,
      ),
      build: (pw.Context context) {
        // Directionality داخل الصفحة أيضاً: يحمي الأجزاء المضمّنة (مثل
        // الجداول) التي قد تتجاهل ثيم الصفحة في إصدارات الحزمة.
        return PdfFonts.rtl(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              // إشارة السهم الصاعد باللون الأسود الصافي بدلاً من شعار المنشأة الملون
              buildThermalArrowLogo(size: 42),
              pw.SizedBox(height: 6),
              pw.Text(
                cleanOrgName,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 16,
                  font: fonts.bold,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (cleanOrgAddress.isNotEmpty)
                pw.Text(
                  cleanOrgAddress,
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
              if (cleanOrgPhone.isNotEmpty)
                pw.Text(
                  'هاتف: $cleanOrgPhone',
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(fontSize: 10),
                ),
              pw.Divider(thickness: 1),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    PdfFonts.sanitize(
                      tx.type == OpType.revenue
                          ? 'فاتورة نقدية مدفوعة (مدفوع نقداً)'
                          : 'فاتورة مبيعات',
                    ),
                    style: pw.TextStyle(
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text('#$cleanRef'),
                ],
              ),
              if (cleanAccountName.isNotEmpty)
                pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text('العميل: $cleanAccountName'),
                ),
              pw.Divider(thickness: 1),
              for (final item in lines) ...[
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Expanded(
                      child: pw.Text(
                        PdfFonts.sanitize(item.name),
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                    ),
                    pw.Text(
                      '${item.quantity} × ${Fmt.money(item.unitPrice)} = ${Fmt.money(item.total)}',
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ],
              pw.Divider(thickness: 1),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'الإجمالي المطلوب:',
                    style: pw.TextStyle(
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    '${Fmt.money(tx.amount)} $cleanCurrency',
                    style: pw.TextStyle(
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              if (paidVal != null && paidVal.isNotEmpty) ...[
                pw.SizedBox(height: 3),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      PdfFonts.sanitize('المبلغ المدفوع مقدماً:'),
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    pw.Text(
                      paidVal,
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
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
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    pw.Text(
                      remainVal,
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
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
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    pw.Text(
                      '0.00 $cleanCurrency',
                      style: pw.TextStyle(
                        font: fonts.bold,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
              pw.SizedBox(height: 6),
              pw.Divider(thickness: 0.6),
              if (cleanSeller.isNotEmpty) ...[
                pw.Text(
                  'الموظف: $cleanSeller',
                  style: pw.TextStyle(
                    fontSize: 9,
                    font: fonts.bold,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
                pw.SizedBox(height: 3),
              ],
              // التاريخ ورقم الهاتف قبل العنصر الأخير مباشرة
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'التاريخ: ${Fmt.date(tx.date)} ${tx.date.hour.toString().padLeft(2, '0')}:${tx.date.minute.toString().padLeft(2, '0')}',
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                  if (cleanOrgPhone.isNotEmpty || cleanAccountPhone.isNotEmpty)
                    pw.Text(
                      'هاتف: ${cleanOrgPhone.isNotEmpty ? cleanOrgPhone : cleanAccountPhone}',
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                cleanFooter,
                style: const pw.TextStyle(fontSize: 9),
                textAlign: pw.TextAlign.center,
              ),
              // الحراري 80مم يضيق عن ختم مائل مقروء — نكتفي بسطر ختم صغير
              // أسفل التذييل.
              if (stamp) ...[
                pw.SizedBox(height: 4),
                pw.Text(
                  PdfFonts.sanitize(kWatermarkText),
                  style: const pw.TextStyle(
                    fontSize: 7,
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
      stamp: stamp,
    ))
        .bytes;
