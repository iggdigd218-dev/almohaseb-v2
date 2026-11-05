/// تفقيط المبالغ بالحروف العربية — نقل حرفي لـ `numberToWords` في `js/utils.js`.
library;

const _ones = [
  '',
  'واحد',
  'اثنان',
  'ثلاثة',
  'أربعة',
  'خمسة',
  'ستة',
  'سبعة',
  'ثمانية',
  'تسعة',
  'عشرة',
  'أحد عشر',
  'اثنا عشر',
  'ثلاثة عشر',
  'أربعة عشر',
  'خمسة عشر',
  'ستة عشر',
  'سبعة عشر',
  'ثمانية عشر',
  'تسعة عشر',
];

const _tens = [
  '',
  'عشرة',
  'عشرون',
  'ثلاثون',
  'أربعون',
  'خمسون',
  'ستون',
  'سبعون',
  'ثمانون',
  'تسعون',
];

const _hundreds = [
  '',
  'مائة',
  'مائتان',
  'ثلاثمائة',
  'أربعمائة',
  'خمسمائة',
  'ستمائة',
  'سبعمائة',
  'ثمانمائة',
  'تسعمائة',
];

const _thousands = {3: 'ألف', 6: 'مليون', 9: 'مليار'};
const _thousandsPlural = {3: 'آلاف', 6: 'ملايين', 9: 'مليارات'};

String _three(int n) {
  var s = '';
  final h = n ~/ 100;
  final r = n % 100;
  if (h > 0) s += '${_hundreds[h]} ';
  if (r > 0) {
    if (r < 20) {
      s += '${_ones[r]} ';
    } else {
      final unit = _ones[r % 10];
      final ten = _tens[r ~/ 10];
      s += unit.isNotEmpty ? '$unit و$ten ' : '$ten ';
    }
  }
  return s.trim();
}

String _group(int n) {
  if (n == 0) return 'صفر';
  final parts = <String>[];
  var g = 0;
  var v = n;
  while (v > 0) {
    final chunk = v % 1000;
    if (chunk != 0) {
      var w = _three(chunk);
      final th = _thousands[g];
      if (th != null) {
        final thPlural = _thousandsPlural[g] ?? th;
        // «ألف» للمفرد، «ألفان» للمثنى، جمع التكسير (آلاف/ملايين/مليارات) للأعداد 3..10، والمفرد لما فوقها.
        if (chunk == 1) {
          w = th;
        } else if (chunk == 2) {
          // (نظافة) الحروف العربية ليست محارف معرّفات في Dart، فـ`$th` ينتهي
          // عند أول حرف عربي — أي أن هذا التعبير مطابق تماماً لـ`${th}ان` لكنه
          // يرضي فحصَي unnecessary_brace و prefer_interpolation معاً.
          w = '$thان';
        } else if (chunk >= 3 && chunk <= 10) {
          w = '$w $thPlural';
        } else {
          w = '$w $th';
        }
      }
      parts.insert(0, w);
    }
    v = v ~/ 1000;
    g += 3;
  }
  return parts.join(' و').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// يحوّل مبلغًا إلى حروف عربية، مع كسور «من المائة».
String numberToWords(num value) {
  final num rounded = (value.abs() * 100).round() / 100;
  final intPart = rounded.floor();
  final frac = ((rounded - intPart) * 100).round();
  var s = _group(intPart);
  if (frac > 0) s += ' و${_group(frac)} من المائة';
  return s;
}
