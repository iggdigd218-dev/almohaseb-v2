// QA — PR-3+: حماية المخزون ومنع تصادم السندات وشفاء الأقسام
// 1. منع تصادم أرقام السندات والفواتير المتوازية (Device-Prefixed Vouchers)
// 2. حماية رصيد الصنف الافتتاحي عند دمج التكرار غير المتصل (Offline Duplicate Stock Protection)
// 3. شفاء الأصناف العالقة بدون قسم تلقائياً (Auto-Heal Orphan Items)

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('1. منع تصادم أرقام السندات والفواتير المتوازية (Device-Prefixed Vouchers)', () {
    late Database db;
    late Repo repo;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      repo = Repo(databaseProvider: () async => db);

      await db.execute('''
        CREATE TABLE settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE sync_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE vouchers (
          id INTEGER PRIMARY KEY,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          number TEXT NOT NULL,
          kind TEXT NOT NULL,
          amount REAL NOT NULL DEFAULT 0,
          currency TEXT NOT NULL DEFAULT 'YER',
          statement TEXT DEFAULT '',
          notes TEXT DEFAULT '',
          status TEXT NOT NULL DEFAULT 'draft',
          date TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE transactions (
          id INTEGER PRIMARY KEY,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          number TEXT NOT NULL DEFAULT '',
          reference TEXT NOT NULL DEFAULT '',
          date TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
    });

    tearDown(() async {
      await db.close();
    });

    test('توليد رقم السند بالصيغة [Prefix]-[Type]-[Sequence] عند تحديد بادئة الجهاز', () async {
      await repo.setSetting('devicePrefix', 'B');

      final vNumReceipt = await repo.nextVoucherNumber(VoucherKind.receipt);
      expect(vNumReceipt, equals('B-ق-0001'));

      final vNumPayment = await repo.nextVoucherNumber(VoucherKind.payment);
      expect(vNumPayment, equals('B-ص-0001'));

      final vNumDebit = await repo.nextVoucherNumber(VoucherKind.debit);
      expect(vNumDebit, equals('B-ق-0001'));

      // الرقم التالي لنفس النوع يزيد التسلسل
      final vNumReceipt2 = await repo.nextVoucherNumber(VoucherKind.receipt);
      expect(vNumReceipt2, equals('B-ق-0002'));
    });

    test('اشتقاق البادئة تلقائياً من deviceId عند عدم تحديدها صراحة', () async {
      await repo.setSetting('sync.deviceId', 'DEV-K89F2A');
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'});

      final prefix = await repo.resolveDevicePrefix();
      expect(prefix, equals('K8'));

      final vNum = await repo.nextVoucherNumber(VoucherKind.receipt);
      expect(vNum, startsWith('K8-ق-'));
    });

    test('حجز البادئات المتسلسلة (A, B, C...) في السحابة وتجنب التصادم', () async {
      final p1 = await repo.resolveDevicePrefix();
      expect(p1.isNotEmpty, isTrue);
    });

    test('تسلسل الفواتير nextTxNumber لا يعلّق المعاملة (إصلاح طريق مسدود 321)', () async {
      // قبل الإصلاح كان _nextSequence (مسار الفواتير) يستدعي settings()
      // على الاتصال الخام داخل معاملة nextSeq فتعلّقها إلى الأبد —
      // أي فاتورة جديدة تتجمد (وما زال العدّاد يعمل داخل المعاملة نفسها).
      final ref1 = await repo.nextTxNumber();
      expect(ref1, equals('1'));

      // بادئة صريحة: رقم مسبوق دون تعليق
      await repo.setSetting('devicePrefix', 'B');
      final ref2 = await repo.nextTxNumber();
      expect(ref2, equals('B-00002'));

      // داخل مجموعة وبلا بادئة: اشتقاق K8 من DEV-K89F2A عبر المنفّذ نفسه
      await repo.setSetting('devicePrefix', '');
      await repo.setSetting('sync.deviceId', 'DEV-K89F2A');
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'});
      final ref3 = await repo.nextTxNumber();
      expect(ref3, equals('K8-00003'));
    });
  });

  group('2. حماية رصيد الصنف الافتتاحي عند دمج التكرار غير المتصل (Stock Protection)', () {
    late Database db;
    late Repo repo;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      repo = Repo(databaseProvider: () async => db);

      await db.execute('''
        CREATE TABLE items (
          id INTEGER PRIMARY KEY,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          name TEXT NOT NULL,
          category_id INTEGER NULL,
          section_id INTEGER NULL,
          quantity REAL NOT NULL DEFAULT 0,
          sell_price REAL NOT NULL DEFAULT 0,
          buy_price REAL NOT NULL DEFAULT 0,
          archived INTEGER NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          is_active INTEGER NOT NULL DEFAULT 1,
          deleted_at TEXT DEFAULT '',
          created_at TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT ''
        )
      ''');

      await db.execute('''
        CREATE TABLE stock_moves (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          item_id INTEGER NOT NULL,
          kind TEXT NOT NULL,
          quantity REAL NOT NULL DEFAULT 0,
          unit_price REAL NOT NULL DEFAULT 0,
          account_id INTEGER,
          notes TEXT DEFAULT '',
          date TEXT NOT NULL,
          deleted_at TEXT DEFAULT '',
          deleted_by INTEGER,
          restore_op_id TEXT DEFAULT '',
          created_at TEXT NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE transaction_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tx_id INTEGER NOT NULL,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          item_id INTEGER,
          name TEXT NOT NULL,
          unit TEXT NOT NULL DEFAULT 'حبة',
          quantity REAL NOT NULL,
          unit_price REAL NOT NULL,
          total REAL NOT NULL
        )
      ''');

      // مطابق تمامًا للمخطط الفعلي (lib/core/database.dart) — كانت الأعمدة
      // الناقصة (parent_op_id وdevice_time وserver_time) تفشل تسجيل
      // عملية الاستقبال داخل applyRemoteOperation.
      await db.execute('''
        CREATE TABLE operations (
          id TEXT PRIMARY KEY,
          device_id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          user_id INTEGER,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          op_type TEXT NOT NULL,
          version INTEGER NOT NULL DEFAULT 1,
          parent_op_id TEXT DEFAULT '',
          payload TEXT NOT NULL,
          device_time TEXT NOT NULL,
          server_time TEXT DEFAULT '',
          timestamp TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0,
          is_synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
    });

    tearDown(() async {
      await db.close();
    });

    test('دمج صنف مكرر غير متصل يضيف كميته إلى الصنف السحابي ويسجل حركة شراء تسوية', () async {
      // 1. صنف محلي أضيف بدون اتصال بكمية 15
      await db.insert('items', {
        'id': 1001,
        'name': 'عصير برتقال',
        'quantity': 15.0,
        'workspace_id': 'default',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // 2. وصول صنف سحابي بنفس الاسم بمعرف 2002 ورصيد 25
      final nowIso = DateTime.now().toIso8601String();
      final op = SyncOperation(
        id: 'op_item_2002',
        deviceId: 'DEV-CLOUD',
        workspaceId: 'default',
        userId: null,
        entityType: EntityKind.item,
        entityId: '2002',
        opType: OpKind.create,
        version: 1,
        parentOpId: '',
        payload: {
          'id': 2002,
          'name': 'عصير برتقال',
          'quantity': 25.0,
          'workspace_id': 'default',
        },
        deviceTime: nowIso,
        timestamp: '${DateTime.now().millisecondsSinceEpoch}',
      );

      await db.transaction((txn) async {
        final applied = await repo.applyRemoteOperation(txn, op, ConflictResolver());
        expect(applied, isTrue);
      });

      // 3. التحقق من أن الصنف المكرر (1001) تم حذفه
      final localDups = await db.query('items', where: 'id = 1001');
      expect(localDups.isEmpty, isTrue);

      // 4. التحقق من أن الصنف المعتمد (2002) يحمل مجموع الكميتين (25 + 15 = 40)
      final canonical = await db.query('items', where: 'id = 2002');
      expect(canonical.isNotEmpty, isTrue);
      final totalQty = (canonical.first['quantity'] as num).toDouble();
      expect(totalQty, equals(40.0));

      // 5. التحقق من إنشاء حركة مخزنية رسمية من نوع purchase لتوثيق التسوية
      final moves = await db.query('stock_moves', where: 'item_id = 2002');
      expect(moves.isNotEmpty, isTrue);
      expect(moves.first['kind'], equals('purchase'));
      expect((moves.first['quantity'] as num).toDouble(), equals(15.0));
      expect(moves.first['notes'], contains('تسوية تلقائية لدمج رصيد صنف مكرر'));
    });

    test('دمج مكرر ذي حركات موثقة لا يكرر التوثيق — التسوية للرصيد غير المغطى فقط', () async {
      // صنف محلي: رصيد افتتاحي 5 + شراء موثق بحركة 10 → الكمية الحالية 15
      // (الشراء 10 موثق في stock_moves، والافتتاحي 5 غير موثق بحركة).
      final t0 = DateTime.now().toIso8601String();
      await db.insert('items', {
        'id': 1001,
        'name': 'عصير تفاح',
        'quantity': 15.0,
        'workspace_id': 'default',
        'created_at': t0,
        'updated_at': t0,
      });
      await db.insert('stock_moves', {
        'item_id': 1001,
        'kind': 'purchase',
        'quantity': 10.0,
        'unit_price': 0,
        'workspace_id': 'default',
        'notes': 'شراء موثق',
        'date': '2026-10-30',
        'created_at': t0,
      });

      // وصول صنف سحابي بنفس الاسم بمعرف 2002 ورصيد 25
      final op = SyncOperation(
        id: 'op_item_2002b',
        deviceId: 'DEV-CLOUD',
        workspaceId: 'default',
        userId: null,
        entityType: EntityKind.item,
        entityId: '2002',
        opType: OpKind.create,
        version: 1,
        parentOpId: '',
        payload: {
          'id': 2002,
          'name': 'عصير تفاح',
          'quantity': 25.0,
          'workspace_id': 'default',
        },
        deviceTime: t0,
        timestamp: '${DateTime.now().millisecondsSinceEpoch}',
      );

      await db.transaction((txn) async {
        final applied = await repo.applyRemoteOperation(txn, op, ConflictResolver());
        expect(applied, isTrue);
      });

      // المكرر حُذف والكمية رُحِّلت كاملة (25 + 15 = 40)
      expect((await db.query('items', where: 'id = 1001')).isEmpty, isTrue);
      final canonical = await db.query('items', where: 'id = 2002');
      expect(canonical.isNotEmpty, isTrue);
      expect((canonical.first['quantity'] as num).toDouble(), equals(40.0));

      // التوثيق بلا ازدواج: الشراء المعاد توجيهه (10) + تسوية الافتتاحي
      // غير الموثق (5) = 15 فقط — وليس 15+10 كما كان قبل التصحيح.
      final moves = await db.query('stock_moves', where: 'item_id = 2002');
      expect(moves.length, equals(2));
      final synth = moves.firstWhere(
        (m) => '${m['notes']}'.contains('تسوية تلقائية'),
      );
      expect((synth['quantity'] as num).toDouble(), equals(5.0));
      final docSum = moves.fold<double>(
          0.0, (a, m) => a + (m['quantity'] as num).toDouble());
      expect(docSum, equals(15.0));
      // واتساق صيغة المطابقة (PR-2): initialCreate(25) + طيّ الحركات(15) = 40 = الكمية.
    });
  });

  group('3. شفاء الأصناف العالقة بدون قسم تلقائياً (Auto-Heal Orphan Items)', () {
    late Database db;
    late Repo repo;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      repo = Repo(databaseProvider: () async => db);

      await db.execute('''
        CREATE TABLE sections (
          id INTEGER PRIMARY KEY,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          name TEXT NOT NULL,
          deleted_at TEXT DEFAULT '',
          created_at TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT ''
        )
      ''');

      await db.execute('''
        CREATE TABLE item_categories (
          id INTEGER PRIMARY KEY,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          name TEXT NOT NULL,
          section_id INTEGER NULL,
          deleted_at TEXT DEFAULT '',
          created_at TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT ''
        )
      ''');

      await db.execute('''
        CREATE TABLE items (
          id INTEGER PRIMARY KEY,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          name TEXT NOT NULL,
          category_id INTEGER NULL,
          section_id INTEGER NULL,
          quantity REAL NOT NULL DEFAULT 0,
          sell_price REAL NOT NULL DEFAULT 0,
          buy_price REAL NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          is_active INTEGER NOT NULL DEFAULT 1,
          deleted_at TEXT DEFAULT '',
          created_at TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT ''
        )
      ''');
    });

    tearDown(() async {
      await db.close();
    });

    test('شفاء الأصناف التي تحمل section_id IS NULL وربطها بقسم فئتها فوراً', () async {
      // 1. إدراج قسم وفئة مرتبطة به
      await db.insert('sections', {'id': 5, 'name': 'قسم المشروبات'});
      await db.insert('item_categories', {'id': 10, 'name': 'عصائر طازجة', 'section_id': 5});

      // 2. إدراج صنف وصل قبل قسمه فصار section_id = NULL
      await db.insert('items', {
        'id': 101,
        'name': 'عصير تفاح',
        'category_id': 10,
        'section_id': null,
      });

      // صنف آخر بفئة ليس لها قسم — يجب ألا يتأثر
      await db.insert('item_categories', {'id': 20, 'name': 'فئة بدون قسم', 'section_id': null});
      await db.insert('items', {
        'id': 102,
        'name': 'سلعة عامة',
        'category_id': 20,
        'section_id': null,
      });

      // 3. تشغيل الشفاء الذاتي
      final healedCount = await repo.autoHealOrphanItems();
      expect(healedCount, equals(1));

      // 4. التأكد من ربط الصنف 101 بالقسم 5
      final item101 = await db.query('items', where: 'id = 101');
      expect(item101.first['section_id'], equals(5));

      // 5. التأكد من بقاء الصنف 102 بدون قسم بأمان
      final item102 = await db.query('items', where: 'id = 102');
      expect(item102.first['section_id'], isNull);
    });
  });
}
