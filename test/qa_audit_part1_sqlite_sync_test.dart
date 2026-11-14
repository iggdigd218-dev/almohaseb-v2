import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/backup_engine.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/sync_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime.now();
  final nowIso = now.toIso8601String();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('qa_audit_part1_');
    db = await databaseFactory.openDatabase('${tmp.path}/audit_part1.db');
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-AUDIT-1');
    await repo.initSyncInfra();
    await db.insert(
      'users',
      {
        'id': 1,
        'name': 'المدير',
        'role': 'admin',
        'permissions': '',
        'is_me': 1,
        'active': 1,
        'created_at': nowIso,
        'updated_at': nowIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.update('devices', {'user_id': 1, 'is_owner': 1},
        where: 'id = ?', whereArgs: ['DEV-AUDIT-1']);
  });

  tearDown(() async {
    try {
      await db.close();
    } catch (_) {}
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('M1: migrateToV31 normalizes FK constraints and cleans orphans',
      () async {
    await db.execute('PRAGMA foreign_keys = OFF');
    // Inject orphan parent_id & section_id into item_categories and items
    await db.insert('item_categories', {
      'id': 101,
      'workspace_id': 'default',
      'name': 'فئة يتيمة',
      'parent_id': 99999,
      'section_id': 88888,
      'created_at': nowIso,
      'updated_at': nowIso,
    });
    await db.insert('items', {
      'id': 201,
      'workspace_id': 'default',
      'name': 'صنف يتيم',
      'category_id': 77777,
      'section_id': 88888,
      'created_at': nowIso,
      'updated_at': nowIso,
    });
    await db.execute('PRAGMA foreign_keys = ON');

    await AppDatabase.migrateToV31(db);

    final catRow =
        (await db.query('item_categories', where: 'id = 101')).first;
    expect(catRow['parent_id'], isNull);
    expect(catRow['section_id'], isNull);

    final itemRow = (await db.query('items', where: 'id = 201')).first;
    expect(itemRow['category_id'], isNull);
    expect(itemRow['section_id'], isNull);

    final fkCheck = await db.rawQuery('PRAGMA foreign_key_check');
    expect(fkCheck, isEmpty);
  });

  test('M2: deleteItemCategory avoids unique index collision on child promote',
      () async {
    final parentId = await repo.saveItemCategory(ItemCategory(
      name: 'رئيسية',
      createdAt: now,
      updatedAt: now,
    ));
    final childId = await repo.saveItemCategory(ItemCategory(
      parentId: parentId,
      name: 'فئة متشابهة',
      createdAt: now,
      updatedAt: now,
    ));
    // Create a soft-deleted root category with the exact same name
    final softDeletedRoot = await db.insert('item_categories', {
      'workspace_id': 'default',
      'name': 'فئة متشابهة',
      'parent_id': null,
      'deleted_at': nowIso,
      'created_at': nowIso,
      'updated_at': nowIso,
    });
    expect(softDeletedRoot, greaterThan(0));

    // Deleting parent should promote child without throwing UNIQUE constraint
    await repo.deleteItemCategory(parentId);

    final promoted =
        (await db.query('item_categories', where: 'id = ?', whereArgs: [childId]))
            .first;
    expect(promoted['parent_id'], isNull);
    expect('${promoted['deleted_at'] ?? ''}', isEmpty);
  });

  test('M3: saveItemCategory prevents duplicate active names under same parent',
      () async {
    await repo.saveItemCategory(ItemCategory(
      name: 'مشروبات',
      createdAt: now,
      updatedAt: now,
    ));
    expect(
      () => repo.saveItemCategory(ItemCategory(
        name: 'مشروبات',
        createdAt: now,
        updatedAt: now,
      )),
      throwsStateError,
    );
  });

  test('M4/M9: exportAll supports withImages & includes trash/notifications',
      () async {
    await db.insert('items', {
      'id': 1,
      'workspace_id': 'default',
      'name': 'صنف بصورة',
      'image': 'media/item_1.jpg',
      'created_at': nowIso,
      'updated_at': nowIso,
    });
    await db.insert('trash', {
      'id': 1,
      'store': 'items',
      'payload': '{"id":9}',
      'label': 'محذوف',
      'created_at': nowIso,
    });
    await db.insert('notifications', {
      'id': 1,
      'workspace_id': 'default',
      'kind': 'info',
      'title': 'تنبيه',
      'body': 'تفاصيل',
      'created_at': nowIso,
    });

    await db.insert(
      'settings',
      {'key': 'logo', 'value': 'media/logo.png'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final fullExport = await repo.exportAll(withImages: true);
    final data = fullExport['data'] as Map<String, Object?>;
    expect(data.containsKey('trash'), isTrue);
    expect(data.containsKey('notifications'), isTrue);
    final settingsWithImg = (data['settings'] as List).cast<Map>();
    expect(settingsWithImg.any((r) => r['key'] == 'logo'), isTrue);

    final noImgExport = await repo.exportAll(withImages: false);
    final noImgData = noImgExport['data'] as Map<String, Object?>;
    final settingsNoImg = (noImgData['settings'] as List).cast<Map>();
    expect(settingsNoImg.any((r) => r['key'] == 'logo'), isFalse);
    expect((noImgExport['images'] as Map), isEmpty);
  });

  test('M7/M8: latestActivityInfoFromDb scans items/accounts beyond tx & package backup passes inspectBackupBytes',
      () async {
    final later = now.add(const Duration(days: 5)).toIso8601String();
    await db.insert('items', {
      'id': 50,
      'workspace_id': 'default',
      'name': 'صنف محدث لاحقاً',
      'created_at': nowIso,
      'updated_at': later,
    });

    final info = await Repo.latestActivityInfoFromDb(db);
    expect(info.readFailed, isFalse);
    expect(info.latest, isNotNull);
    expect(
      info.latest!.millisecondsSinceEpoch,
      greaterThanOrEqualTo(DateTime.parse(later).millisecondsSinceEpoch - 1000),
    );

    final pkgFile = await BackupEngine.createNexoraPackage(
      repo,
      outputDirectory: tmp,
      customFileName: 'test_part1.nexora',
    );
    expect(await pkgFile.exists(), isTrue);
    final inspected = await BackupEngine.inspectBackupFile(
      repo,
      pkgFile,
      enforceSyncGuard: false,
    );
    expect(inspected.dateReadFailed, isFalse);
    await inspected.dispose();
  });

  test('S2: ConflictResolver unifies server_time -> timestamp -> version -> deviceId',
      () {
    final resolver = ConflictResolver();
    const olderServerNewerClock = SyncOperation(
      id: 'op-1',
      workspaceId: 'default',
      deviceId: 'DEV-Z',
      userId: 1,
      parentOpId: '',
      entityType: EntityKind.item,
      entityId: '1',
      opType: OpKind.update,
      payload: {},
      timestamp: '2026-10-02T12:00:00.000Z',
      deviceTime: '2026-10-02T12:00:00Z',
      serverTime: '1700000001000',
      version: 1,
    );
    const newerServerOlderClock = SyncOperation(
      id: 'op-2',
      workspaceId: 'default',
      deviceId: 'DEV-A',
      userId: 1,
      parentOpId: '',
      entityType: EntityKind.item,
      entityId: '1',
      opType: OpKind.update,
      payload: {},
      timestamp: '2026-10-01T12:00:00.000Z',
      deviceTime: '2026-10-01T12:00:00Z',
      serverTime: '1700000005000',
      version: 1,
    );

    expect(
      resolver.decide(
        exists: true,
        localVersion: 1,
        localLatest: olderServerNewerClock,
        incoming: newerServerOlderClock,
      ),
      isTrue,
    );
    expect(
      resolver.decide(
        exists: true,
        localVersion: 1,
        localLatest: newerServerOlderClock,
        incoming: olderServerNewerClock,
      ),
      isFalse,
    );
  });

  test('S3/S4/S11: SyncQueueOps atomic markSynced, reconcileSyncedQueue & backoff jitter',
      () async {
    final q = SyncQueueOps(db);
    await db.insert('operations', {
      'id': 'OP-S3-1',
      'workspace_id': 'default',
      'device_id': 'DEV-AUDIT-1',
      'entity_type': 'account',
      'entity_id': '1',
      'op_type': 'create',
      'payload': '{}',
      'version': 1,
      'parent_op_id': '',
      'timestamp': nowIso,
      'device_time': nowIso,
      'synced': 0,
      'is_synced': 0,
    });
    await db.insert('operations', {
      'id': 'OP-S4-1',
      'workspace_id': 'default',
      'device_id': 'DEV-AUDIT-1',
      'entity_type': 'account',
      'entity_id': '2',
      'op_type': 'create',
      'payload': '{}',
      'version': 1,
      'parent_op_id': '',
      'timestamp': nowIso,
      'device_time': nowIso,
      'synced': 0,
      'is_synced': 0,
    });

    final q1 = await q.enqueue('OP-S3-1', target: SyncTarget.cloud);
    await q.markSynced(q1);
    final op1 =
        (await db.query('operations', where: 'id = ?', whereArgs: ['OP-S3-1']))
            .first;
    expect(op1['is_synced'], 1);
    expect(op1['synced'], 1);

    // S4: Simulate queue row falsely marked synced while operation is_synced=0
    final q2 = await q.enqueue('OP-S4-1', target: SyncTarget.cloud);
    await db.update('sync_queue', {'status': 'synced'},
        where: 'id = ?', whereArgs: [q2]);
    final healed = await q.reconcileSyncedQueue(cloudReady: true);
    expect(healed, greaterThanOrEqualTo(1));
    final q2Row =
        (await db.query('sync_queue', where: 'id = ?', whereArgs: [q2])).first;
    expect(q2Row['status'], SyncStatus.pending.name);

    // S11: Permanent error schedules longer backoff than transient error
    await db.insert('operations', {
      'id': 'OP-S11-1',
      'workspace_id': 'default',
      'device_id': 'DEV-AUDIT-1',
      'entity_type': 'account',
      'entity_id': '3',
      'op_type': 'create',
      'payload': '{}',
      'version': 1,
      'parent_op_id': '',
      'timestamp': nowIso,
      'device_time': nowIso,
      'synced': 0,
      'is_synced': 0,
    });
    final q3 = await q.enqueue('OP-S11-1', target: SyncTarget.cloud);
    await q.markFailed(q3, 'cloud-auth-failed: 403');
    final q3Row =
        (await db.query('sync_queue', where: 'id = ?', whereArgs: [q3])).first;
    final nextTry = DateTime.parse('${q3Row['next_try_at']}');
    expect(nextTry.difference(DateTime.now()).inSeconds, greaterThanOrEqualTo(40));
  });
}
