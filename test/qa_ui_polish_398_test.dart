import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// (3.98.34) حزمة إعادة التصميم: تثبيت القرارات البصرية بقارئ مصدري
/// حتى لا تعود الأزرار العائمة أو التبويبات الأفقية أو تكرار بطاقات المظهر.
void main() {
  String read(String p) => File(p).readAsStringSync();

  /// كل ملفات واجهة المستخدم (بلا ملفات الثيم/الأدوات المشتركة).
  List<File> uiFiles() => Directory('lib/ui')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  group('UI-POLISH — حزمة 3.98.34', () {
    test('UI-01 لا يوجد أي FloatingActionButton في الواجهة', () {
      final offenders = uiFiles()
          .where((f) => read(f.path).contains('FloatingActionButton'))
          .map((f) => f.path)
          .toList();
      expect(offenders, isEmpty, reason: 'أزرار عائمة متبقية: $offenders');
    });

    test('UI-02 الإعدادات قائمة صفحات بلا تبويبات أفقية', () {
      final s = read('lib/ui/settings_screen.dart');
      expect(s, isNot(contains('DefaultTabController')));
      expect(s, isNot(contains('TabBarView')));
      expect(s, isNot(contains('TabBar(')));
      expect(s, contains('class _SettingsHome'));
      for (final title in const [
        'بيانات المؤسسة',
        'الفواتير والبيع',
        'المظهر والأصوات',
        'الأمان',
        'النظام والمزامنة',
      ]) {
        expect(s, contains(title), reason: 'قسم مفقود: $title');
      }
    });

    test('UI-03 بطاقات المظهر غير مكرّرة في الإعدادات', () {
      final s = read('lib/ui/settings_screen.dart');
      expect(s, isNot(contains('ThemeModeSelectorCard')));
      expect(read('lib/ui/appearance_screen.dart'),
          contains('ThemeModeSelectorCard'));
    });

    test('UI-04 شبكة المنتجات ثلاثة أعمدة على الهاتف', () {
      final s = read('lib/ui/inventory_screen.dart');
      expect(s, contains('w >= 900 ? 5 : (w >= 600 ? 4 : 3)'));
    });

    test('UI-05 دائرة المزامنة بلا إطار وسماكة 1.5', () {
      final s = read('lib/ui/widgets/sync_arrows_indicator.dart');
      expect(s, contains('_kStroke = 1.5'));
      expect(s, isNot(contains('Border.all')));
      expect(s, isNot(contains('BoxDecoration')));
    });

    test('UI-06 بطاقة العملات مقلّصة إلى 156', () {
      expect(read('lib/ui/dashboard_screen.dart'), contains('height: 156'));
    });

    test('UI-07 زر حفظ المنتج ثابت خارج منطقة التمرير', () {
      final s = read('lib/ui/inventory_screen.dart');
      expect(s, contains('SingleChildScrollView'));
      // (3.98.35) حشو ثابت: showDialog يرفع النافذة فوق الكيبورد بنفسه،
      // فإضافة viewInsets داخل البطاقة تُنتج فراغاً أبيض أسفل زر الحفظ.
      expect(s, contains('EdgeInsets.fromLTRB(12, 8, 12, 10)'));
      expect(s, isNot(contains('8 + MediaQuery.viewInsetsOf(context).bottom')));
    });

    test('UI-08 قائمة النواقص صفحة Scaffold مستقلة', () {
      final s = read('lib/ui/inventory_screen.dart');
      expect(s, contains('Future<void> openShortagesListSheet'));
      expect(s, contains('MaterialPageRoute'));
      expect(s, contains('fullPage'));
    });

    test('UI-09 تنظيف محارف التصدير غير المدعومة', () {
      final s = read('lib/core/pdf_fonts.dart');
      expect(s, contains(r'\u2370')); // ⍰
      expect(s, contains(r'\uFFFD'));
      expect(s, contains(r'\uE000'));
      expect(s, contains(r'\u{10000}-\u{10FFFF}'));
    });

    test('UI-10 إشعار إكمال البيانات كل يومين كحد أقصى', () {
      final s = read('lib/ui/widgets/profile_completion_nudge.dart');
      expect(s, contains("prefsKey = 'profileNudge.lastShownAt'"));
      expect(s, contains('Duration(days: 2)'));
      expect(s, contains('إكمال الآن'));
      expect(s, contains('لاحقاً'));
    });

    test('UI-11 قالب إدخال مدمج موحّد في الثيم', () {
      final s = read('lib/core/theme.dart');
      expect(s, contains('insetPadding'));
      expect(s, contains('minWidth: 36'));
    });

    test('UI-12 الشريط السفلي يتوسطه زر + عملية والمساعد الذكي منقول للقائمة والإعدادات', () {
      final home = read('lib/ui/home_shell.dart');
      final settings = read('lib/ui/settings_screen.dart');
      expect(home, contains('class _CenterOperationButton'));
      expect(home, contains("'عملية'"));
      expect(home, isNot(contains('class _MarkedGearIcon')));
      expect(home, contains('المساعد الذكي (Gemini)'));
      expect(settings, contains('المساعد الذكي (Gemini)'));
    });

    test('UI-13 دائرة المزامنة بقوسين متناظرين وألوان فاتحة وحركات دوران ونبض', () {
      final sync = read('lib/ui/widgets/sync_arrows_indicator.dart');
      expect(sync, contains('_drawClockwiseArcArrow'));
      expect(sync, contains('_kSweep = 2.68'));
      expect(sync, contains('0xFF10B981'));
      expect(sync, contains('0xFF0EA5E9'));
      expect(sync, contains('_triggerTapSpin'));
      expect(sync, contains('_triggerPulseSpin'));
    });

    test('UI-14 بطاقة العضو موحدة الاسم بلا تكرار لقب الدور ولا الجهاز/المستخدم', () {
      final dev = read('lib/ui/devices_screen.dart');
      expect(dev, contains('resolveMemberUnifiedName'));
      expect(dev, isNot(contains('roleDisplayName(')));
      expect(dev, isNot(contains("_smallLabel('الجهاز'")));
      expect(dev, isNot(contains("_smallLabel('المستخدم'")));
    });

    test('UI-15 نموذج الصنف يشترط الحقول الأساسية ويضم نقطة استبعاد النواقص', () {
      final inv = read('lib/ui/inventory_screen.dart');
      expect(inv, contains('name.length < 2'));
      expect(inv, contains('_includeInShortages'));
      expect(inv, contains('excludeFromShortages'));
      expect(inv, contains('مفعّل في قائمة النواقص'));
    });

    test('UI-16 نافذة الحساب بطاقة منبثقة مدمجة من 3 صفوف وقائمة مشاركة علوية', () {
      final acc = read('lib/ui/account_form.dart');
      expect(acc, contains('showDialog<bool>'));
      expect(acc, contains('_buildShareMenuButton'));
      expect(acc, isNot(contains('showModalBottomSheet')));
    });

    test('UI-17 نافذة العملية بطاقة منبثقة مدمجة من 4 صفوف بلا تفاصيل زائدة', () {
      final tx = read('lib/ui/tx_form.dart');
      expect(tx, contains('showDialog<Object>'));
      expect(tx, contains('_compactTypeBar'));
      expect(tx, contains('_accountAndDateRow'));
      expect(tx, contains('_descriptionWithImageField'));
      expect(tx, isNot(contains('طبيعة العملية على الحساب')));
      expect(tx, isNot(contains('إخفاء التفاصيل الإضافية')));
      expect(tx, isNot(contains('رقم مرجعي')));
    });
  });
}
