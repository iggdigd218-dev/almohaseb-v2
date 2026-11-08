// QA — (3.98.39 / الملاحظة 4) اختبار أولوية البحث: الملاحظات درجة ثانية.
//
// المطلوب من العميل: البحث يضمّ `notes` لكن بنظام درجتين — تطابق الاسم/
// الباركود (sku)/PLU/رقم الصنف (#id)/الفئة أولاً، ثم الملاحظات وحدها.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/item_search.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('درجات مطابقة البحث', () {
    test('SEARCH-01 تطابق الاسم = الدرجة الأولى', () {
      expect(
        itemSearchTier(query: 'شاي', name: 'شاي أحمر', notes: ''),
        ItemSearchTier.primary,
      );
    });

    test('SEARCH-02 تطابق الملاحظات فقط = الدرجة الثانية', () {
      expect(
        itemSearchTier(
            query: 'شاي', name: 'مشروب ساخن', notes: 'منبه: شاي مخزّن'),
        ItemSearchTier.notes,
      );
    });

    test('SEARCH-03 لا مطابقة = صفر', () {
      expect(
        itemSearchTier(query: 'بن', name: 'شاي', notes: 'ورق'),
        ItemSearchTier.none,
      );
    });

    test('SEARCH-04 الباركود (sku) و PLU ورقم الصنف من الدرجة الأولى', () {
      expect(itemSearchTier(query: '90001', name: 'صنف', sku: '90001'),
          ItemSearchTier.primary);
      expect(itemSearchTier(query: '4557', name: 'صنف', plu: 4557),
          ItemSearchTier.primary);
      expect(itemSearchTier(query: '#812', name: 'صنف', id: 812),
          ItemSearchTier.primary);
    });

    test('SEARCH-05 الفئة من الدرجة الأولى', () {
      expect(itemSearchTier(query: 'مشروبات', name: 'صنف', category: 'مشروبات'),
          ItemSearchTier.primary);
    });

    test('SEARCH-06 كلمات متعددة: كل الكلمات في الاسم = الدرجة الأولى', () {
      expect(
        itemSearchTier(query: 'شاي أحمر', name: 'شاي أحمر فاخر'),
        ItemSearchTier.primary,
      );
    });

    test('SEARCH-07 كلمات متعددة موزعة بين الاسم والملاحظات = درجة ثانية', () {
      expect(
        itemSearchTier(
            query: 'شاي مخزّن', name: 'شاي أحمر', notes: 'مخزّن بارد'),
        ItemSearchTier.notes,
      );
    });

    test('SEARCH-08 تطبيع عربي: أ/ا و ة/ه و ى/ي والأرقام العربية', () {
      expect(itemSearchTier(query: 'اصناف', name: 'أصناف'),
          ItemSearchTier.primary);
      expect(itemSearchTier(query: 'مكتبه', name: 'مكتبة'), ItemSearchTier.primary);
      expect(itemSearchTier(query: '٩٠٠١', name: 'صنف', sku: '9001'),
          ItemSearchTier.primary);
    });

    test('SEARCH-09 استعلام فارغ لا يُصفّي شيئاً', () {
      expect(itemSearchTier(query: '   ', name: 'أي صنف'),
          ItemSearchTier.primary);
    });

    test('SEARCH-10 الترتيب: الدرجة الأولى قبل الملاحظات مهما كان الفرز', () {
      final items = [
        {'name': 'مشروب ساخن', 'notes': 'شاي مخزّن'}, // ملاحظات فقط
        {'name': 'شاي أحمر', 'notes': ''}, // الدرجة الأولى
      ];
      final tiers = [
        for (final it in items)
          itemSearchTier(
              query: 'شاي', name: it['name']!, notes: it['notes']!),
      ];
      expect(tiers.first, ItemSearchTier.notes);
      expect(tiers.last, ItemSearchTier.primary);
      // القسمة المستخدمة في الشاشة: الأساسي أولاً ثم الملاحظات.
      final sorted = [
        ...items.where((it) =>
            itemSearchTier(
                query: 'شاي', name: it['name']!, notes: it['notes']!) >=
            ItemSearchTier.primary),
        ...items.where((it) =>
            itemSearchTier(
                query: 'شاي', name: it['name']!, notes: it['notes']!) <
            ItemSearchTier.primary),
      ];
      expect(sorted.first['name'], 'شاي أحمر');
      expect(sorted.last['name'], 'مشروب ساخن');
    });
  });

  group('Repo.items على قاعدة حقيقية (SQL)', () {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    late Repo repo;

    setUp(() async {
      // singleInstance: false حتى تحصل كل حالة على قاعدة ذاكرة مستقلة.
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      await AppDatabase.createSchema(db);
      repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
      final now = DateTime.now();
      await repo.saveItem(Item(
        name: 'شاي أحمر',
        sellPrice: 100,
        quantity: 1,
        notes: '',
        createdAt: now,
        updatedAt: now,
      ));
      await repo.saveItem(Item(
        name: 'مشروب ساخن',
        sellPrice: 100,
        quantity: 1,
        notes: 'يخزّن بجوار الشاي',
        createdAt: now,
        updatedAt: now,
      ));
      await repo.saveItem(Item(
        name: 'سكر',
        sellPrice: 100,
        quantity: 1,
        notes: '',
        createdAt: now,
        updatedAt: now,
      ));
    });

    test('SEARCH-11 repo.items يضم الملاحظات ويضع مطابقة الاسم أولاً', () async {
      final results = await repo.items(q: 'شاي');
      expect(results.map((i) => i.name).toList(), ['شاي أحمر', 'مشروب ساخن'],
          reason: 'مطابقة الاسم أولاً ثم مطابقة الملاحظات فقط');
    });

    test('SEARCH-12 repo.items يدعم كلمات مفتاحية متعددة', () async {
      final results = await repo.items(q: 'مشروب شاي');
      expect(results.map((i) => i.name).toList(), ['مشروب ساخن']);
    });

    test('SEARCH-13 استعلام لا يطابق شيئاً يعيد قائمة فارغة', () async {
      expect(await repo.items(q: 'قهوة تركية'), isEmpty);
    });
  });
}
