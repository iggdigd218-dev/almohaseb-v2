// (3.98.39 / الملاحظة 4) منطق بحث الأصناف الموحّد — مصدر حقيقة واحد
// لشاشة المخزون وشاشة نقطة البيع (POS) وكل دوال تصفية الأصناف.
//
// القاعدة المطلوبة من العميل: الملاحظات (notes) تُضمّ إلى حقول البحث، لكن
// بنظام **أولوية درجتين**:
//   1) تطابق الاسم / الباركود (sku) / PLU / رقم الصنف (#id) / الفئة.
//   2) تطابق الملاحظات فقط — تأتي بعد كل نتائج الدرجة الأولى مهما كان
//      ترتيب الفرز المختار.
// ودعم كلمات مفتاحية متعددة (كل كلمة يجب أن تتحقق)، مع تطبيع عربي
// (أ/إ/آ ← ا، ى ← ي، ة ← ه، أرقام عربية ← لاتينية).
library;

import 'format.dart';

/// درجات مطابقة البحث.
abstract final class ItemSearchTier {
  /// لا مطابقة.
  static const int none = 0;

  /// مطابقة في الملاحظات فقط (الدرجة الثانية).
  static const int notes = 1;

  /// مطابقة في الاسم/الباكورد/PLU/رقم الصنف/الفئة (الدرجة الأولى).
  static const int primary = 2;
}

/// كلمات البحث بعد التطبيع (مع إزالة علامة # من بداية الكلمة).
List<String> itemSearchTokens(String query) {
  final normalized = Fmt.normArabic(query).toLowerCase();
  if (normalized.trim().isEmpty) return const [];
  return normalized
      .split(RegExp(r'\s+'))
      .map((t) => t.startsWith('#') ? t.substring(1) : t)
      .where((t) => t.isNotEmpty)
      .toList();
}

/// يحسب درجة مطابقة [query] لهذا الصنف.
///
/// استعلام فارغ ⇒ [ItemSearchTier.primary] (أي «لا تصفية»).
int itemSearchTier({
  required String query,
  required String name,
  String sku = '',
  String category = '',
  String notes = '',
  Object? plu,
  Object? id,
}) {
  final tokens = itemSearchTokens(query);
  if (tokens.isEmpty) return ItemSearchTier.primary;

  final primaryHaystacks = <String>[
    Fmt.normArabic(name).toLowerCase(),
    Fmt.normArabic(category).toLowerCase(),
    Fmt.normArabic(sku).toLowerCase(),
    if (plu != null) Fmt.normArabic('$plu').toLowerCase(),
    if (id != null) Fmt.normArabic('$id').toLowerCase(),
  ].where((s) => s.isNotEmpty).toList();

  bool inPrimary(String t) => primaryHaystacks.any((h) => h.contains(t));

  final notesHaystack = Fmt.normArabic(notes).toLowerCase();

  if (tokens.every(inPrimary)) return ItemSearchTier.primary;
  if (tokens.every((t) => inPrimary(t) || notesHaystack.contains(t))) {
    return ItemSearchTier.notes;
  }
  return ItemSearchTier.none;
}
