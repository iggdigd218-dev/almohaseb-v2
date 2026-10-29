// (PR-2) اختبارات مصالحة المخزون بعد التثبيت النظيف ودفع حالة الصنف
// سحابياً عند البيع/المرتجع — يغطي:
//  1. صيغة المالك الحرفية (افتتاحية − مبيعات + مرتجعات) للبيانات القديمة
//     الخالية من حركات المخزون (سبب «التصفير بعد إعادة التثبيت»).
//  2. الجمع بين المصدرين: بيع قديم بلا حركة + بيع جديد بحركة (لا ازدواج).
//  3. عدم المساس بالأصناف السليمة (الحالة الصحية no-op).
//  4. المرتجع يرفع الرصيد المصحح للسحابة (رفيق __from_stock_move بversion+1).
//  5. حذف المرتجع يعكس إرجاعه الموسوم حصراً (والقديم غير الموسوم لا يُمس).
//  6. زر الصيانة: مصالحة + دفع sحابي (__qty_changed=1).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime.now();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pr2_stock_');
    db = await databaseFactory.openDatabase('${tmp.path}/test.db');
    await AppDatabase.createSchema(db);

    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-PR2');
    await repo.initSyncInfra();

    final nowIso = now.toIso8601String();
    await db.insert('users', {
      'id': 1,
      'name': 'المدير العام',
      'role': 'admin',
      'permissions': '',
      'is_me': 1,
      'active': 1,
      'created_at': nowIso,
      'updated_at': nowIso,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.update('devices', {'user_id': 1, 'is_owner': 1},
        where: 'id = ?', whereArgs: ['DEV-PR2']);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  /// إدراج فاتورة بيع «قديمة الطراز»: سطر فاتورة بلا حركة مخزون ولا رفيق
  /// سحابي — يحاكي بيانات ما قبل الرفع المصاحب (سبب الخلل الأصلي).
  Future<int> insertLegacySaleTx(int itemId, double qty) async {
    final nowIso = DateTime.now().toIso8601String();
    final txId = 990000 + DateTime.now().millisecondsSinceEpoch % 9000;
    await db.insert('transactions', {
      'id': txId,
      'workspace_id': 'default',
      'type': 'revenue',
      'amount': qty * 10,
      'currency': 'YER',
      'status': 'done',
      'sync_state': 'synced',
      'reference': 'LEGACY-$txId',
      'notes': 'فاتورة قديمة قبل الرفع المصاحب',
      'date': nowIso,
      'created_at': nowIso,
      'updated_at': nowIso,
    });
    await db.insert('transaction_items', {
      'tx_id': txId,
      'workspace_id': 'default',
      'item_id': itemId,
      'name': 'صنف تجريبي',
      'unit': 'حبة',
      'quantity': qty,
      'unit_price': 10,
      'total': qty * 10,
    });
    return txId;
  }

  Future<int> makeItem(double qty) => repo.saveItem(Item(
        name: 'صنف PR-2 ${DateTime.now().microsecondsSinceEpoch}',
        buyPrice: 5,
        sellPrice: 10,
        quantity: qty,
        createdAt: now,
        updatedAt: now,
      ));

  Future<double> qtyOf(int itemId) async =>
      ((await db.query('items', columns: ['quantity'],
              where: 'id = ?', whereArgs: [itemId], limit: 1))
              .first['quantity'] as num)
          .toDouble();

  group('PR-2: مصالحة المخزون بعد التثبيت النظيف', () {
    test('١ — صيغة المالك: افتتاحية − مبيعات (بيانات قديمة بلا حركات)', () async {
      final itemId = await makeItem(100);
      await insertLegacySaleTx(itemId, 30);

      // محاكاة التثبيت النظيف: الكمية كما نزلت من السحابة (افتتاحية قديمة)
      expect(await qtyOf(itemId), 100);

      final changed = <int>[];
      final fixed = await ApplyRemoteOp.reconcileInventoryQuantities(
        db,
        onChanged: (id, prev, next) => changed.add(id),
      );
      expect(fixed, 1);
      expect(await qtyOf(itemId), 70); // 100 − 30
      expect(changed, [itemId]);

      // توافق: إعادة التشغيل لا تغير شيئاً
      final again = await ApplyRemoteOp.reconcileInventoryQuantities(db);
      expect(again, 0);
      expect(await qtyOf(itemId), 70);
    });

    test('٢ — الجمع بين مصدرين: بيع قديم بلا حركة + بيع جديد بحركة (لا ازدواج)',
        () async {
      final itemId = await makeItem(100);
      await insertLegacySaleTx(itemId, 30); // قديم: بلا حركة
      await repo.saveTx(
        Tx(
          type: OpType.revenue,
          amount: 50,
          currency: 'YER',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
        items: [
          InvoiceLine(
            itemId: itemId,
            name: 'صنف PR-2',
            quantity: 5,
            unitPrice: 10,
          ),
        ],
      );
      expect(await qtyOf(itemId), 95); // 100 − 5 (الحديثة فقط)

      final fixed = await ApplyRemoteOp.reconcileInventoryQuantities(db);
      expect(fixed, 1);
      expect(await qtyOf(itemId), 65); // 100 − 30 − 5
    });

    test('٣ — الأصناف السليمة لا تُمس (no-op)', () async {
      final itemId = await makeItem(100);
      await repo.saveTx(
        Tx(
          type: OpType.revenue,
          amount: 100,
          currency: 'YER',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
        items: [
          InvoiceLine(itemId: itemId, name: 'صنف PR-2', quantity: 10, unitPrice: 10),
        ],
      );
      expect(await qtyOf(itemId), 90);

      expect(await ApplyRemoteOp.reconcileInventoryQuantities(db), 0);
      expect(await qtyOf(itemId), 90);
    });

    test('٤ — المرتجع يرفع الرصيد المصحح للسحابة (رفيق version+1)', () async {
      final itemId = await makeItem(100);
      final saleTx = Tx(
        type: OpType.revenue,
        amount: 50,
        currency: 'YER',
        reference: 'S-1',
        date: now,
        createdAt: now,
        updatedAt: now,
      );
      final saleId = await repo.saveTx(
        saleTx,
        items: [InvoiceLine(itemId: itemId, name: 'صنف PR-2', quantity: 5, unitPrice: 10)],
      );
      expect(await qtyOf(itemId), 95);

      final retId = await repo.processSalesReturn(
        originalTx: saleTx.copyWith(id: saleId),
        returnLines: [
          InvoiceLine(itemId: itemId, name: 'صنف PR-2', quantity: 2, unitPrice: 10),
        ],
      );
      expect(await qtyOf(itemId), 97); // 95 + 2

      // الرفع السحابي: عملية تحديث صنف تحمل الرصيد النهائي ورفيق الحركة
      final ops = await db.query('operations',
          where: "entity_type = 'item' AND entity_id = '$itemId'",
          orderBy: 'version ASC');
      final retMoveOps = await db.rawQuery(
        "SELECT payload FROM operations WHERE entity_type = 'item' AND entity_id = ? "
        "AND payload LIKE '%__from_stock_move%' ORDER BY version DESC LIMIT 1",
        [itemId],
      );
      expect(retMoveOps, isNotEmpty);
      final payload = retMoveOps.first['payload'] as String;
      expect(payload, contains('"quantity":97.0'));
      // الإصدار يتصاعد (version+1) لا يثبت
      final versions = ops.map((o) => o['version'] as int).toList();
      expect(versions.toSet().length, versions.length);

      // ── حذف المرتجع يعكس إرجاعه الموسوم حصراً
      await repo.deleteTx(retId);
      expect(await qtyOf(itemId), 95); // 97 − 2
    });

    test('٥ — حذف مرتجع قديم غير موسوم لا يخصم شيئاً (توافق خلفي)', () async {
      final itemId = await makeItem(100);
      // مرتجع قديم الطراز: tx + سطر بلا أي حركة إرجاع
      final nowIso = DateTime.now().toIso8601String();
      final legacyRetId = 991000 + DateTime.now().millisecondsSinceEpoch % 9000;
      await db.insert('transactions', {
        'id': legacyRetId,
        'workspace_id': 'default',
        'type': 'credit',
        'amount': 20,
        'currency': 'YER',
        'status': 'done',
        'sync_state': 'synced',
        'original_tx_id': '123',
        'reference': 'LEGRET-$legacyRetId',
        'notes': 'مرتجع من الفاتورة #123 [ORIG_TX:123]',
        'date': nowIso,
        'created_at': nowIso,
        'updated_at': nowIso,
      });
      await db.insert('transaction_items', {
        'tx_id': legacyRetId,
        'workspace_id': 'default',
        'item_id': itemId,
        'name': 'صنف تجريبي',
        'quantity': 2,
        'unit_price': 10,
        'total': 20,
      });

      await repo.deleteTx(legacyRetId);
      expect(await qtyOf(itemId), 100); // لم يُخصم شيء — لا حركة موسومة
    });

    test('٦ — زر الصيانة: مصالحة + دفع سحابي فوري', () async {
      // تهيئة ناقل سحابي (كما على جهاز مرتبط فعلاً) حتى تتشكل صفوف
      // الطابور — بلا خادم مهيأ لا تُدرج صفوف cloud بحسب تصميم المسجّل.
      await repo.setSetting(
          'cloudBackendUrl', 'https://nexora-test-rtdb.firebaseio.com');
      final itemId = await makeItem(80);
      await insertLegacySaleTx(itemId, 25);

      final fixed = await repo.reconcileInventory(pushToCloud: true);
      expect(fixed, 1);
      expect(await qtyOf(itemId), 55); // 80 − 25

      final pushed = await db.rawQuery(
        "SELECT payload, version FROM operations "
        "WHERE entity_type = 'item' AND entity_id = ? AND payload LIKE '%__reconciled%'",
        [itemId],
      );
      expect(pushed, isNotEmpty);
      final payload = pushed.first['payload'] as String;
      expect(payload, contains('"quantity":55.0'));
      expect(payload, contains('"__qty_changed":1'));
      expect(pushed.first['version'] as int, greaterThan(1)); // version+1

      // الطابور جاهز للرفع للسحابة
      final queued = await db.rawQuery(
        "SELECT COUNT(*) AS n FROM sync_queue WHERE operation_id IN "
        "(SELECT id FROM operations WHERE entity_type='item' AND entity_id=?)",
        [itemId],
      );
      expect((queued.first['n'] as int?) ?? 0, greaterThan(0));
    });
  });
}
