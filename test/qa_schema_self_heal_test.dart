// اختبارات تعافي المخطط الذاتي.
//
// العلة التي تحرسها هذه الاختبارات (حادثة مستخدم على أندرويد):
//   DatabaseException(no such table: operations) عند حفظ حساب أو فاتورة.
// السبب: `Database.execute` في sqflite على أندرويد ينفّذ **أول جملة فقط**
// من سكربت متعدد الجُمل ويتجاهل الباقي بصمت، فتُنشأ الجداول الأولى ويغيب
// `operations`/`sync_queue` — ثم يُسجَّل مفتاح `schema_ensured_v` كأن كل شيء
// سليم، فلا يُعاد الفحص أبداً.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/recorder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openMemory() => databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );

Future<Set<String>> _tables(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  return {for (final r in rows) '${r['name']}'};
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('execSchemaScript ينفّذ كل جمل السكربت لا أولها فقط', () async {
    final db = await _openMemory();
    addTearDown(db.close);

    await AppDatabase.execSchemaScript(db, '''
      CREATE TABLE IF NOT EXISTS t_first (id INTEGER PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS t_second (id INTEGER PRIMARY KEY);
      CREATE INDEX IF NOT EXISTS idx_second ON t_second(id);
      CREATE TABLE IF NOT EXISTS t_third (id INTEGER PRIMARY KEY);
    ''');

    final names = await _tables(db);
    expect(
      names.containsAll({'t_first', 't_second', 't_third'}),
      isTrue,
      reason: 'كل جدول في السكربت يجب أن يُنشأ — لا الأول وحده',
    );
  });

  test('execSchemaScript آمن عند التكرار (IF NOT EXISTS)', () async {
    final db = await _openMemory();
    addTearDown(db.close);

    const script = '''
      CREATE TABLE IF NOT EXISTS t_a (id INTEGER PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS t_b (id INTEGER PRIMARY KEY);
    ''';
    await AppDatabase.execSchemaScript(db, script);
    await AppDatabase.execSchemaScript(db, script);

    final names = await _tables(db);
    expect(names.containsAll({'t_a', 't_b'}), isTrue);
  });

  test('hasCoreSyncTables يفحص sqlite_master فعلياً لا مفتاح الإصدار', () async {
    final db = await _openMemory();
    addTearDown(db.close);

    expect(await AppDatabase.hasCoreSyncTables(db), isFalse,
        reason: 'قاعدة فارغة: الجدولان غائبان');
    await AppDatabase.ensureSyncTablesForExecutor(db);
    expect(await AppDatabase.hasCoreSyncTables(db), isTrue);
  });

  test('ensureSyncTablesForExecutor يضيف عمود is_synced لقاعدة قديمة',
      () async {
    final db = await _openMemory();
    addTearDown(db.close);

    // قاعدة قديمة: operations بلا عمود is_synced ولا sync_queue.
    await db.execute(
      'CREATE TABLE operations ('
      'id TEXT PRIMARY KEY, device_id TEXT NOT NULL, workspace_id TEXT NOT NULL, '
      'user_id INTEGER, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, '
      'op_type TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1, '
      "parent_op_id TEXT DEFAULT '', payload TEXT NOT NULL, "
      "device_time TEXT NOT NULL, server_time TEXT DEFAULT '', "
      'timestamp TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0)',
    );

    await AppDatabase.ensureSyncTablesForExecutor(db);

    final cols = await db.rawQuery('PRAGMA table_info(operations)');
    expect(cols.any((c) => c['name'] == 'is_synced'), isTrue);
    expect(await AppDatabase.hasCoreSyncTables(db), isTrue);
  });

  test('SyncRecorder يتعافى تلقائياً حين يكون جدول operations مفقوداً',
      () async {
    final db = await _openMemory();
    addTearDown(db.close);

    // بيئة ناقصة كتلك التي ينتجها بناء قديم على أندرويد.
    await db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );

    final recorder = SyncRecorder(
      db: db,
      deviceId: 'dev-qa',
      workspaceId: 'default',
    );

    // الحفظ يجب أن ينجح رغم غياب operations (تعافٍ ذاتي داخلي).
    final id = await recorder.record(
      entityType: EntityKind.account,
      entityId: 'acc-qa-1',
      opType: OpKind.create,
      payload: {'name': 'عميل اختبار'},
    );

    expect(id, isNotEmpty);
    expect(await AppDatabase.hasCoreSyncTables(db), isTrue,
        reason: 'الجداول الناقصة أُنشئت تلقائياً');
    final ops = await db.query('operations');
    expect(ops.length, 1, reason: 'العملية سُجّلت بعد التعافي');
  });

  test('SyncRecorder لا يبتلع أخطاء أخرى غير «جدول مفقود»', () async {
    final db = await _openMemory();
    addTearDown(db.close);
    await db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)',
    );
    await AppDatabase.ensureSyncTablesForExecutor(db);
    // جدول معطوب فعلاً: عمود NOT NULL غائب من الإدراج لا يمكن إصلاحه بالتعافي.
    await db.execute('DROP TABLE operations');
    await db.execute(
      'CREATE TABLE operations (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    );

    final recorder = SyncRecorder(
      db: db,
      deviceId: 'dev-qa',
      workspaceId: 'default',
    );

    await expectLater(
      recorder.record(
        entityType: EntityKind.account,
        entityId: 'acc-qa-2',
        opType: OpKind.create,
        payload: {'name': 'عميل اختبار'},
      ),
      throwsA(isA<DatabaseException>()),
      reason: 'الخطأ الحقيقي يجب أن يظهر لا أن يُبتلع',
    );
  });
}
