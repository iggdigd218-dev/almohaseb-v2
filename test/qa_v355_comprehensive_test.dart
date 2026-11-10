// اختبارات ميزات الإصدار 3.98.40 (المهام 1-5):
// 1. تحديث إجمالي رأس المال وقيمة البيع ديناميكياً حسب الفلتر.
// 2. اقتراحات البيان الذكية من العمليات السابقة.
// 3. تطابق اسم المدير بين الملف الشخصي والقائمة الجانبية وإدارة المجموعة.
// 4. توحيد اسم الموظف في سند الإشعار والسند الحراري وتنظيف الرموز الزائدة.
// 5. موثوقية روابط التحميل المباشر وروابط المتصفح.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/device_names.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/receipt_image.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/update_installer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('V355-01 تحديث إجمالي رأس المال وقيمة البيع ديناميكياً حسب الفلتر', () {
    test('حساب رأس المال وقيمة البيع على القائمة المصفاة فقط', () {
      final now = DateTime.now();
      final allItems = [
        Item(id: 1, name: 'صنف 1', buyPrice: 100, sellPrice: 150, quantity: 10, categoryId: 1, sectionId: 1, createdAt: now, updatedAt: now),
        Item(id: 2, name: 'صنف 2', buyPrice: 200, sellPrice: 300, quantity: 5, categoryId: 2, sectionId: 1, createdAt: now, updatedAt: now),
        Item(id: 3, name: 'صنف 3', buyPrice: 50, sellPrice: 80, quantity: 20, categoryId: 3, sectionId: 2, createdAt: now, updatedAt: now),
        Item(id: 4, name: 'صنف رصيده صفر', buyPrice: 100, sellPrice: 150, quantity: 0, categoryId: 1, sectionId: 1, createdAt: now, updatedAt: now),
        Item(id: 5, name: 'صنف رصيده سالب', buyPrice: 100, sellPrice: 150, quantity: -2, categoryId: 1, sectionId: 1, createdAt: now, updatedAt: now),
      ];

      // حساب الإجمالي الكلي (الأصناف ذات الكمية الموجبة فقط):
      double calcCost(List<Item> list) =>
          list.where((it) => it.quantity > 0).fold(0.0, (sum, it) => sum + (it.quantity * it.buyPrice));
      double calcSell(List<Item> list) =>
          list.where((it) => it.quantity > 0).fold(0.0, (sum, it) => sum + (it.quantity * it.sellPrice));

      expect(calcCost(allItems), 100 * 10 + 200 * 5 + 50 * 20); // 1000 + 1000 + 1000 = 3000
      expect(calcSell(allItems), 150 * 10 + 300 * 5 + 80 * 20); // 1500 + 1500 + 1600 = 4600

      // فلترة حسب القسم 1:
      final section1Items = allItems.where((it) => it.sectionId == 1).toList();
      expect(calcCost(section1Items), 1000 + 1000); // 2000
      expect(calcSell(section1Items), 1500 + 1500); // 3000

      // فلترة حسب الفئة 2:
      final cat2Items = allItems.where((it) => it.categoryId == 2).toList();
      expect(calcCost(cat2Items), 1000);
      expect(calcSell(cat2Items), 1500);
    });
  });

  group('V355-02 اقتراحات البيان الذكية التلقائية من العمليات السابقة', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexora_desc_test_');
      db = await databaseFactory.openDatabase('${tmp.path}/desc_qa.db',
          options: OpenDatabaseOptions(
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          ));
      await AppDatabase.createSchema(db);
      AppDatabase.overrideForTest(db);
      repo = Repo();
      await repo.initSyncInfra();
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      await tmp.delete(recursive: true);
    });

    test('اقتراحات البيان تعطي الأولوية لعمليات الحساب ثم الأكثر تكراراً', () async {
      final now = DateTime.now().toIso8601String();
      // إنشاء حسابين
      await db.insert('accounts', {
        'id': 101,
        'workspace_id': 'ws-1',
        'name': 'العميل الأول',
        'kind': 'customer',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('accounts', {
        'id': 102,
        'workspace_id': 'ws-1',
        'name': 'العميل الثاني',
        'kind': 'customer',
        'created_at': now,
        'updated_at': now,
      });

      // إدراج عمليات سابقة
      Future<void> addTx(int accId, String desc) async {
        await db.insert('transactions', {
          'workspace_id': 'ws-1',
          'account_id': accId,
          'type': 'debit',
          'amount': 500,
          'rate': 1.0,
          'currency': 'YER',
          'description': desc,
          'date': now,
          'created_at': now,
          'updated_at': now,
        });
      }

      await addTx(101, 'دفعة نقدية تحت الحساب');
      await addTx(101, 'دفعة نقدية تحت الحساب');
      await addTx(102, 'قيمة بضاعة مشتريات');
      await addTx(102, 'قيمة بضاعة مشتريات');
      await addTx(102, 'قيمة بضاعة مشتريات');

      // عند البحث بكلمة «دفعة» لحساب 101
      final res1 = await repo.transactionDescriptionSuggestions(
        query: 'دفعة',
        accountId: 101,
      );
      expect(res1, contains('دفعة نقدية تحت الحساب'));

      // عند فتح الاقتراحات العامة لحساب 101 تعطي عملياته أولوية
      final resAll = await repo.transactionDescriptionSuggestions(
        accountId: 101,
      );
      expect(resAll.first, 'دفعة نقدية تحت الحساب');
      expect(resAll, contains('قيمة بضاعة مشتريات'));
    });
  });

  group('V355-03 تطابق اسم المدير وتوحيد الهوية في جميع الشاشات', () {
    test('resolveOwnerDisplayName يعتمد الاسم الصريح المحفوظ ولا يرتد لحساب جوجل', () {
      final name = resolveOwnerDisplayName(
        profileOwnerName: 'منير قايد',
        accountName: 'Munir qaid senan a',
        deviceName: 'المدير 🫡',
        userName: 'المدير',
      );
      expect(name, 'منير قايد');
    });

    test('إذا لم يُكتب اسم صريح يُستخدم اسم الحساب السحابي كبديل', () {
      final name = resolveOwnerDisplayName(
        profileOwnerName: '',
        accountName: 'Munir qaid',
        deviceName: 'المدير',
        userName: 'المدير',
      );
      expect(name, 'Munir qaid');
    });
  });

  group('V355-04 توحيد اسم الموظف في سند الإشعار وتنظيف الرموز الزائدة', () {
    test('تجريد لاحقة الجهاز مثل (I) وإرجاع الاسم الموحد', () {
      final st = {
        'profile.owner_name': 'منير قايد',
        'sync.deviceName': 'جهاز الإدارة',
      };
      final now = DateTime.now();
      final receiptData = ReceiptData.fromTx(
        tx: Tx(
          id: 1,
          type: OpType.debit,
          amount: 1000,
          currency: 'YER',
          date: now,
          createdAt: now,
          updatedAt: now,
          cashierName: 'فخامة المدير 🫡 (I)',
        ),
        account: Account(
          id: 1,
          name: 'عميل 1',
          kind: AccountKind.customer,
          createdAt: now,
          updatedAt: now,
        ),
        currency: const CurrencyDef('YER', 'ريال يمني', 'ر.ي', 0),
        settings: st,
      );

      // يجب أن يتخلص من الاسم المزخرف واللاحقة (I) ويعرض الاسم الموحد
      expect(receiptData.sellerOrDevice, 'منير قايد');
    });
  });

  group('V355-05 موثوقية روابط التحميل المباشر', () {
    test('روابط التحميل المباشر بسطر واحد تشير لمرآة Fastly الصحيحة', () {
      expect(UpdateInstaller.kShortAndroidArm64Url,
          'https://iggdigd218-dev.github.io/almohaseb-v2/Almohaseb-Plus-arm64.apk');
      expect(UpdateInstaller.kShortWindowsUrl,
          'https://iggdigd218-dev.github.io/almohaseb-v2/NexoraSetup.exe');
    });
  });
}
