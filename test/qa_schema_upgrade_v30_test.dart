// QA — (3.98.39) اختبار انحدار إلزامي لترقية المخطط V29 ⇒ V30.
//
// العلة الأصلية: قاعدة بيانات تعمل بـ `user_version = 29` وفيها
// `sync_meta.schema_ensured_v = 29` كانت تتخطّى `ensureFullSchema` تماماً،
// فيبقى العمود `items.exclude_from_shortages` غائباً ⇒ كل INSERT/UPDATE
// صنف يفشل بـ `table items has no column named exclude_from_shortages`
// وتُعرض للمستخدم رسالة «تعارض في البيانات المسجلة».
//
// هذا الاختبار يبني قاعدة «V29 حقيقية» (بلا العمود وبلا الفهرس المركّب)
// ثم يُرقّيها ويغطي الرحلة الكاملة: حفظ صنف جديد + تعديله + استقبال صنف
// من المزامنة (apply_remote).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;

  /// هل يوجد العمود فعلاً في الجدول؟
  Future<bool> hasColumn(String table, String column) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.any((r) => '${r['name']}' == column);
  }

  Future<bool> hasIndex(String name) async {
    final rows = await db
        .rawQuery("SELECT name FROM sqlite_master WHERE type='index' AND name=?",
            [name]);
    return rows.isNotEmpty;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_v30_');
    db = await databaseFactory.openDatabase('${tmp.path}/qa.db',
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ));

    // 1) مخطط كامل (V30) ثم نُعيده صناعياً إلى هيئة V29:
    //    حذف العمود + حذف الفهرس القديم/الجديد + إرجاع أرقام الإصدار.
    await AppDatabase.createSchema(db);
    await db.execute('DROP INDEX IF EXISTS idx_items_shortage');
    await db.execute('DROP INDEX IF EXISTS idx_item_categories_parent_name');
    try {
      await db.execute('ALTER TABLE items DROP COLUMN exclude_from_shortages');
    } catch (_) {
      // نسخ SQLite أقدم من 3.35 لا تدعم DROP COLUMN — نعيد بناء الجدول.
      await db.execute('ALTER TABLE items RENAME TO items_v30_tmp');
      await db.execute('''
        CREATE TABLE items (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          workspace_id  TEXT NOT NULL DEFAULT 'default',
          name          TEXT NOT NULL,
          category_id   INTEGER,
          section_id    INTEGER,
          plu           INTEGER,
          sku           TEXT DEFAULT '',
          unit          TEXT DEFAULT 'حبة',
          buy_price     REAL NOT NULL DEFAULT 0,
          sell_price    REAL NOT NULL DEFAULT 0,
          quantity      REAL NOT NULL DEFAULT 0,
          min_quantity  REAL NOT NULL DEFAULT 0,
          currency      TEXT NOT NULL DEFAULT 'YER',
          category      TEXT DEFAULT '',
          notes         TEXT DEFAULT '',
          image         TEXT DEFAULT '',
          archived      INTEGER NOT NULL DEFAULT 0,
          is_deleted    INTEGER NOT NULL DEFAULT 0,
          is_active     INTEGER NOT NULL DEFAULT 1,
          deleted_at    TEXT DEFAULT '',
          deleted_by    INTEGER,
          restore_op_id TEXT DEFAULT '',
          created_at    TEXT NOT NULL,
          updated_at    TEXT NOT NULL
        )''');
      await db.execute('DROP TABLE items_v30_tmp');
    }
    await db.execute('PRAGMA user_version = 29');
    await db.insert(
      'sync_meta',
      {'key': 'schema_ensured_v', 'value': '29'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    AppDatabase.overrideForTest(db);
    repo = Repo();
    await repo.initSyncInfra();
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test('V30-01 الحالة الأولية: قاعدة V29 بلا العمود (إثبات العلة)', () async {
    expect(await hasColumn('items', 'exclude_from_shortages'), isFalse);
    expect('${(await db.rawQuery('PRAGMA user_version')).first.values.first}',
        '29');
  });

  test('V30-02 migrateToV30 تضيف العمود والفهارس وتحدّث schema_ensured_v',
      () async {
    await AppDatabase.migrateToV30(db);

    expect(await hasColumn('items', 'exclude_from_shortages'), isTrue,
        reason: 'العمود الغائب هو سبب فشل كل حفظ صنف');
    expect(await hasIndex('idx_items_shortage'), isTrue);
    expect(await hasIndex('idx_item_categories_parent_name'), isTrue,
        reason: 'فهرس الفئات المركّب يمنع تكرار الاسم داخل نفس الأب');
    expect(await hasIndex('idx_item_categories_name'), isFalse,
        reason: 'الفهرس القديم (اسم مطلق بلا نطاق أب) يجب أن يُحذف');

    final meta = await db.query('sync_meta',
        where: 'key = ?', whereArgs: ['schema_ensured_v'], limit: 1);
    expect('${meta.first['value']}', '30',
        reason: 'بدون تحديث هذا المفتاح يتخطى الفتح التالي ensureFullSchema');

    // idempotent: نداء ثانٍ لا يرمي ولا يُفسد شيئاً.
    await AppDatabase.migrateToV30(db);
    expect(await hasColumn('items', 'exclude_from_shortages'), isTrue);
  });

  test('V30-03 بعد الترقية: حفظ صنف جديد وتعديله ينجحان (بلا «تعارض بيانات»)',
      () async {
    await AppDatabase.migrateToV30(db);

    final now0 = DateTime.now();
    final newId = await repo.saveItem(
      Item(
        name: 'صنف ترقية V30',
        sellPrice: 500,
        buyPrice: 300,
        quantity: 7,
        currency: 'YER',
        unit: 'حبة',
        notes: 'ملاحظة اختبار الترقية',
        createdAt: now0,
        updatedAt: now0,
      ),
    );
    expect(newId, greaterThan(0));

    final rows = await db.query('items', where: 'id = ?', whereArgs: [newId]);
    expect(rows.length, 1);
    expect(
      (rows.first['exclude_from_shortages'] as num?)?.toInt() ?? 0,
      0,
      reason: 'القيمة الافتراضية لعمود V30 يجب أن تكون 0',
    );

    // تعديل الصنف نفسه (UPDATE) — كان يفشل بنفس الخطأ.
    await repo.saveItem(Item(
      id: newId,
      name: 'صنف ترقية V30 (معدّل)',
      sellPrice: 650,
      buyPrice: 300,
      quantity: 9,
      currency: 'YER',
      unit: 'حبة',
      notes: 'بعد التعديل',
      createdAt: now0,
      updatedAt: DateTime.now(),
    ));
    final after = await db.query('items', where: 'id = ?', whereArgs: [newId]);
    expect('${after.first['name']}', contains('معدّل'));
    expect((after.first['quantity'] as num).toDouble(), 9);
  });

  test('V30-04 بعد الترقية: استقبال صنف من المزامنة (apply_remote) ينجح',
      () async {
    await AppDatabase.migrateToV30(db);

    final now = DateTime.now().toIso8601String();
    final remote = SyncOperation(
      id: 'op-item-v30-remote',
      deviceId: 'DEVICE-REMOTE',
      workspaceId: repo.requireWorkspaceId,
      userId: null,
      version: 1,
      parentOpId: '',
      timestamp: now,
      entityType: EntityKind.item,
      entityId: '777701',
      opType: OpKind.create,
      payload: {
        'id': 777701,
        'workspace_id': repo.requireWorkspaceId,
        'name': 'صنف وارد من السحابة',
        'sku': '90001',
        'plu': 777701,
        'unit': 'حبة',
        'buy_price': 100,
        'sell_price': 150,
        'quantity': 3,
        'min_quantity': 1,
        'currency': 'YER',
        'category': '',
        'notes': '',
        'archived': 0,
        'is_deleted': 0,
        'is_active': 1,
        'exclude_from_shortages': 0,
        'created_at': now,
        'updated_at': now,
      },
      deviceTime: now,
    );

    final applied = await db.transaction(
        (txn) => repo.applyRemoteOperation(txn, remote, ConflictResolver()));
    expect(applied, isTrue, reason: 'العملية الواردة يجب أن تُطبَّق بلا استثناء');

    final rows =
        await db.query('items', where: 'id = ?', whereArgs: [777701]);
    expect(rows.length, 1);
    expect('${rows.first['name']}', 'صنف وارد من السحابة');
  });

  test('V30-05 ensureLatestColumns شبكة أمان مستقلة عن بوابة alreadyEnsured',
      () async {
    // نُعيد الحالة إلى V29 ونحذف العمود من جديد.
    await db.execute('DROP INDEX IF EXISTS idx_items_shortage');
    try {
      await db.execute('ALTER TABLE items DROP COLUMN exclude_from_shortages');
    } catch (_) {
      // في حال عدم دعم DROP COLUMN نتحقق من الدالة فقط.
    }
    await AppDatabase.ensureLatestColumns(db);
    expect(await hasColumn('items', 'exclude_from_shortages'), isTrue,
        reason: 'الدالة تُنادى في onOpen خارج بوابة alreadyEnsured');
  });
}
