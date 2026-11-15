import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/backup_engine.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/catalog_recovery_service.dart';
import 'package:nexora_app/data/sync/cloud_firebase_transport.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/device_id.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/snapshot_apply.dart';
import 'package:nexora_app/data/sync/sync_quarantine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _AtomicMockCloud {
  final Map<String, Object?> store = {};
  final List<String> putOrder = [];
  int mockServerTimeMs = 1765000123000;

  static http.Response _jsonResp(Object? data, [int status = 200]) =>
      http.Response.bytes(
        utf8.encode(data == null ? 'null' : jsonEncode(data)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Object? _resolveServerTimestamp(Object? v) {
    if (v is Map) {
      if (v['.sv'] == 'timestamp') {
        return mockServerTimeMs;
      }
      return {
        for (final e in v.entries) '${e.key}': _resolveServerTimestamp(e.value),
      };
    }
    if (v is List) {
      return [for (final item in v) _resolveServerTimestamp(item)];
    }
    return v;
  }

  http.Client client() => MockClient((req) async {
        if (req.method == 'POST') {
          if (req.url.host.contains('securetoken')) {
            return _jsonResp({
              'id_token': 'TOK-ATOMIC',
              'refresh_token': 'REF-ATOMIC',
              'expires_in': '3600',
              'user_id': 'UID-ATOMIC',
            });
          }
          return _jsonResp({
            'idToken': 'TOK-ATOMIC',
            'refreshToken': 'REF-ATOMIC',
            'expiresIn': '3600',
            'localId': 'UID-ATOMIC',
          });
        }
        final path = req.url.path;
        if (req.method == 'PUT') {
          putOrder.add(path);
          final resolved = _resolveServerTimestamp(jsonDecode(req.body));
          store[path] = resolved;
          return _jsonResp(resolved);
        }
        if (req.method == 'PATCH') {
          final existing = store[path] is Map
              ? Map<String, Object?>.from(store[path] as Map)
              : <String, Object?>{};
          final patch = _resolveServerTimestamp(jsonDecode(req.body));
          if (patch is Map) {
            existing.addAll(Map<String, Object?>.from(patch));
          }
          store[path] = existing;
          return _jsonResp(existing);
        }
        if (req.method == 'DELETE') {
          store.remove(path);
          return _jsonResp(null);
        }
        if (path.endsWith('/subscription.json')) {
          final direct = store[path];
          if (direct is Map && (direct['max_devices'] is num) && (direct['max_devices'] as num) > 1) {
            return _jsonResp(direct);
          }
          final fallback = <String, Object?>{
            'status': 'active',
            'plan_type': 'enterprise',
            'max_devices': 10,
            'is_active': true,
            'created_at': 1765000000000,
            'expires_at': 1999999999000,
            'features': {'all': true},
          };
          if (direct is Map) {
            for (final e in direct.entries) {
              fallback['${e.key}'] = e.value;
            }
            fallback['max_devices'] = 10;
            fallback['plan_type'] = 'enterprise';
          }
          store[path] = fallback;
          return _jsonResp(fallback);
        }
        final direct = store[path];
        if (direct != null) return _jsonResp(direct);
        final prefix = path.replaceAll('.json', '');
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            final child = e.key
                .substring(prefix.length + 1)
                .replaceAll('.json', '');
            children[Uri.decodeComponent(child)] = e.value;
          }
        }
        if (children.isNotEmpty) return _jsonResp(children);
        return _jsonResp(null);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const url = 'https://atomic-qa.firebaseio.com';
  late Directory tmp;
  late Database dbA;
  late Database dbB;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime(2026, 11, 1);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_atomic_qa_');
    Future<Database> open(String name) => databaseFactory.openDatabase(
          '${tmp.path}/$name.db',
          options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
          ),
        );
    dbA = await open('owner');
    dbB = await open('member');
    await AppDatabase.createSchema(dbA);
    await AppDatabase.createSchema(dbB);
    repoA = Repo(databaseProvider: () async => dbA);
    repoB = Repo(databaseProvider: () async => dbB);
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
    await repoA.setSetting('cloudBackendUrl', url);
    await repoA.setSetting('cloudCode', 'ATM99');
  });

  tearDown(() async {
    if (dbA.isOpen) await dbA.close();
    if (dbB.isOpen) await dbB.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test(
      'ATOMIC-01: اللقطة الذرية تُرفع وتُفحص بالبصمة قبل إشارة الموافقة، وتمنع التراجع الزمني وترقية العضو بالبريد',
      () async {
    final cloud = _AtomicMockCloud();
    await repoA.saveAccount(Account(
      name: 'عميل سيادي',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await repoA.saveItem(Item(
      name: 'صنف سيادي 1',
      sellPrice: 1200,
      quantity: 30,
      plu: 42,
      createdAt: now,
      updatedAt: now,
    ));
    await repoA.setSetting('businessName', 'مؤسسة السيادة');

    // بريد محلي سابق في جهاز العضو لا يجوز أن يرقّيه مالكاً بعد الانضمام
    await repoB.setSetting('account.email', 'member.personal@test.com');

    final invite = await http.runWithClient(
      () => CloudJoin.createInvite(repoA),
      cloud.client,
    );
    final devB = await ensureDeviceId(repoB);

    await http.runWithClient(
      () => CloudJoin.approveJoinRequest(
        repoA,
        backendUrl: invite.backendUrl,
        deviceId: devB,
        deviceName: 'ايمن ل ...',
        roleCode: 'cashier',
        workspaceId: invite.workspaceId,
      ),
      cloud.client,
    );

    final snapKey = '/workspaces/${invite.workspaceId}/joinSnapshot.json';
    final approvedReqKey =
        '/workspaces/${invite.workspaceId}/joinRequests/$devB.json';
    final snapIdx = cloud.putOrder.indexOf(snapKey);
    final reqIdx = cloud.putOrder.indexOf(approvedReqKey);
    expect(snapIdx, greaterThanOrEqualTo(0));
    expect(reqIdx, greaterThan(snapIdx),
        reason: 'يجب رفع اللقطة الذرية بالكامل قبل كتابة إشارة approved');

    final snapRec = cloud.store[snapKey] as Map<String, Object?>;
    expect(snapRec['schemaVersion'], AppDatabase.schemaVersion);
    expect(snapRec['serverWatermarkMs'], cloud.mockServerTimeMs);
    expect('${snapRec['checksum'] ?? ''}', isNotEmpty);
    expect(snapRec['counts'], isA<Map>());

    // تجربة عبث بالبصمة يفشل مع CloudJoinException قبل مسح بيانات العضو
    final originalChecksum = snapRec['checksum'];
    snapRec['checksum'] = '0000tampered';
    await expectLater(
      http.runWithClient(
        () => CloudJoin.join(
          repoB,
          backendUrl: invite.backendUrl,
          token: invite.token,
          workspaceId: invite.workspaceId,
          cloudCode: invite.cloudCode,
        ),
        cloud.client,
      ),
      throwsA(isA<CloudJoinException>()),
    );
    snapRec['checksum'] = originalChecksum;

    // الآن انضمام سليم بالبصمة الصحيحة
    await http.runWithClient(
      () => CloudJoin.join(
        repoB,
        backendUrl: invite.backendUrl,
        token: invite.token,
        workspaceId: invite.workspaceId,
        cloudCode: invite.cloudCode,
      ),
      cloud.client,
    );

    expect(await repoB.workspaceMode(), 'member');
    expect(await repoB.isWorkspaceOwner(), isFalse,
        reason: 'العضو لا يترقى لمالك بسبب البريد المحلي');

    final cursorRows = await dbB.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: ['last_synced_cursor:${invite.workspaceId}'],
    );
    expect(cursorRows.single['value'], '${cloud.mockServerTimeMs}',
        reason: 'المؤشر يُضبط على serverWatermarkMs بدقة بدون إرجاع 60 ثانية');
    final pluRows = await dbB.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: ['last_plu:${invite.workspaceId}'],
    );
    expect(pluRows.single['value'], '42');
  });

  test(
      'SOVEREIGN-01: حارس السيادة يعزل تعديلات العضو على المستخدمين والصلاحيات وهوية المنشأة',
      () async {
    final ownerId = repoA.requireDeviceId;
    final ws = repoA.requireWorkspaceId;
    await repoA.setSetting('managerName', 'المدير الأصلي للمنشأة');

    final memberOpUser = SyncOperation(
      id: 'op-member-user-hijack',
      deviceId: 'DEV-MEMBER-ROGUE',
      workspaceId: ws,
      userId: 2,
      entityType: EntityKind.user,
      entityId: '1',
      opType: OpKind.update,
      version: 1,
      parentOpId: '',
      payload: {'id': 1, 'name': 'عضو منتحل', 'role': 'admin'},
      deviceTime: DateTime.now().toIso8601String(),
      timestamp: DateTime.now().toIso8601String(),
    );
    final memberOpSetting = SyncOperation(
      id: 'op-member-brand-hijack',
      deviceId: 'DEV-MEMBER-ROGUE',
      workspaceId: ws,
      userId: 2,
      entityType: EntityKind.setting,
      entityId: 'managerName',
      opType: OpKind.settings,
      version: 1,
      parentOpId: '',
      payload: {'key': 'managerName', 'value': 'اسم مدير مخترق'},
      deviceTime: DateTime.now().toIso8601String(),
      timestamp: DateTime.now().toIso8601String(),
    );

    final ok1 = await dbA.transaction((txn) =>
        repoA.applyRemoteOperation(txn, memberOpUser, ConflictResolver()));
    final ok2 = await dbA.transaction((txn) =>
        repoA.applyRemoteOperation(txn, memberOpSetting, ConflictResolver()));

    expect(ok1, isFalse);
    expect(ok2, isFalse);
    expect((await repoA.settings())['managerName'], 'المدير الأصلي للمنشأة');

    final pendingQ = await SyncQuarantineStore.pendingOps(
      dbA,
      workspaceId: ws,
      reason: SyncQuarantineStore.kReasonSovereignViolation,
    );
    expect(pendingQ, hasLength(2));

    // عملية من المالك الحقيقي تُقبل
    final ownerSettingOp = SyncOperation(
      id: 'op-owner-brand-valid',
      deviceId: ownerId,
      workspaceId: ws,
      userId: 1,
      entityType: EntityKind.setting,
      entityId: 'managerName',
      opType: OpKind.settings,
      version: 2,
      parentOpId: '',
      payload: {'key': 'managerName', 'value': 'المدير العام المعتمد'},
      deviceTime: DateTime.now().toIso8601String(),
      timestamp: DateTime.now().toIso8601String(),
    );
    final okOwner = await dbA.transaction((txn) =>
        repoA.applyRemoteOperation(txn, ownerSettingOp, ConflictResolver()));
    expect(okOwner, isTrue);
    expect((await repoA.settings())['managerName'], 'المدير العام المعتمد');
  });

  test(
      'ISOLATION-01: تطابق المعرف لدى العضو يطبق In-Place Upsert بدون ترقيم وهمي، وناقل السحابة يرفض ops مساحتها default',
      () async {
    await repoB.bindWorkspaceId('WS-ISOLATED-1');
    await dbB.insert(
      'sync_meta',
      {'key': 'workspaceMode', 'value': 'member'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await dbB.insert(
      'devices',
      {
        'id': repoB.requireDeviceId,
        'workspace_id': 'WS-ISOLATED-1',
        'name': 'عضو 1',
        'is_paired': 1,
        'is_owner': 0,
        'revoked_at': '',
        'expelled_at': '',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // صنف محلي بمعرف 10 لدى العضو بطابع أقدم
    final olderIso = now.subtract(const Duration(minutes: 5)).toIso8601String();
    final newerIso = now.toIso8601String();
    await dbB.insert('items', {
      'id': 10,
      'workspace_id': 'WS-ISOLATED-1',
      'name': 'صنف عضو محلي',
      'plu': 10,
      'sku': '900010',
      'created_at': olderIso,
      'updated_at': olderIso,
    });
    await dbB.insert('operations', {
      'id': 'local-item-10-old',
      'device_id': repoB.requireDeviceId,
      'workspace_id': 'WS-ISOLATED-1',
      'entity_type': 'item',
      'entity_id': '10',
      'op_type': 'create',
      'payload': '{"id":10,"name":"صنف عضو محلي"}',
      'version': 1,
      'parent_op_id': '',
      'device_time': olderIso,
      'timestamp': olderIso,
      'synced': 0,
      'is_synced': 0,
    });

    final cloudItem10 = SyncOperation(
      id: 'remote-owner-item-10',
      deviceId: 'DEV-OWNER',
      workspaceId: 'WS-ISOLATED-1',
      userId: 1,
      entityType: EntityKind.item,
      entityId: '10',
      opType: OpKind.create,
      version: 1,
      parentOpId: '',
      payload: {
        'id': 10,
        'workspace_id': 'WS-ISOLATED-1',
        'name': 'صنف المالك رقم 10',
        'plu': 10,
        'sku': '900010',
        'updated_at': newerIso,
      },
      deviceTime: newerIso,
      timestamp: newerIso,
    );

    final applied = await dbB.transaction((txn) =>
        repoB.applyRemoteOperation(txn, cloudItem10, ConflictResolver()));
    expect(applied, isTrue);
    final allItems = await dbB.query('items');
    expect(allItems, hasLength(1),
        reason: 'تطابق المعرف يعني نفس الصنف 100% — تحديث في مكانه بدون فصل أو ترقيم وهمي');
    expect(allItems.single['id'], 10);
    expect(allItems.single['name'], 'صنف المالك رقم 10');

    // التحقق من رفض ناقل السحابة لأي عملية قادمة بمساحة default عندما المساحة الحقيقية معيّنة
    final cloud = _AtomicMockCloud();
    cloud.store['/workspaces/WS-ISOLATED-1/operations/OP-LEAK-DEFAULT.json'] = {
      'id': 'OP-LEAK-DEFAULT',
      'device_id': 'DEV-FOREIGN',
      'workspace_id': 'default',
      'entity_type': 'account',
      'entity_id': '505',
      'op_type': 'create',
      'version': 1,
      'parent_op_id': '',
      'payload': {'id': 505, 'name': 'تسريب مساحات'},
      'device_time': now.toIso8601String(),
      'timestamp': now.toIso8601String(),
      'server_time': 1765000200000,
    };
    final transport = CloudFirebaseTransport(
      repo: repoB,
      dbProvider: () async => dbB,
      backendUrl: url,
      workspaceId: 'WS-ISOLATED-1',
    );
    final pulledCount = await http.runWithClient(
      () => transport.pull(resolver: ConflictResolver()),
      cloud.client,
    );
    expect(pulledCount, 0);
    expect(
        await dbB.query('accounts', where: 'id = ?', whereArgs: [505]), isEmpty);
  });

  test(
      'RECOVERY-01: تعطيل أداة الاسترجاع الجماعي undoAutoMerges يمنع إحياء الأصناف المحذوفة ناعماً أو الإخلال بالأرصدة',
      () async {
    final ws = repoA.requireWorkspaceId;
    final nowIso = now.toIso8601String();

    await dbA.insert('items', {
      'id': 1,
      'workspace_id': ws,
      'name': 'شاي كبوس',
      'sell_price': 500,
      'quantity': 10.0,
      'is_deleted': 0,
      'is_active': 1,
      'deleted_at': '',
      'created_at': nowIso,
      'updated_at': nowIso,
    });
    await dbA.insert('items', {
      'id': 2,
      'workspace_id': ws,
      'name': 'سكر ناعم',
      'sell_price': 300,
      'quantity': 15.0,
      'is_deleted': 1,
      'is_active': 0,
      'deleted_at': nowIso,
      'created_at': nowIso,
      'updated_at': nowIso,
    });
    await dbA.insert('accounts', {
      'id': 50,
      'workspace_id': ws,
      'name': 'عميل بعد الانضمام',
      'kind': 'customer',
      'created_at': nowIso,
      'updated_at': nowIso,
    });
    await dbA.insert('transactions', {
      'id': 700,
      'workspace_id': ws,
      'account_id': 50,
      'type': 'sale',
      'amount': 500,
      'currency': 'YER',
      'date': nowIso,
      'created_at': nowIso,
      'updated_at': nowIso,
    });

    final preview = await CatalogRecoveryService.previewRecovery(repoA);
    expect(preview.hasRecoverableIssues, isFalse);

    await expectLater(
      () => CatalogRecoveryService.undoAutoMerges(repoA),
      throwsA(isA<UnsupportedError>()),
    );

    // الصنف النشط #1 والصنف المحذوف ناعماً #2 والفاتورة #700 بقيت دون أي تعديل أعمى
    final item1 = (await dbA.query('items', where: 'id = 1')).single;
    expect((item1['quantity'] as num).toDouble(), 10.0);

    final item2 = (await dbA.query('items', where: 'id = 2')).single;
    expect(item2['is_deleted'], 1);
    expect('${item2['deleted_at'] ?? ''}', isNotEmpty);

    expect(await dbA.query('transactions', where: 'id = 700'), hasLength(1));
  });

  test(
      'RECOVERY-02: الاسترجاع الجراحي لكتالوج الأصناف من نسخة .nexora يعيد المفقود ويحفظ الفواتير والكميات الحية',
      () async {
    final secId = await repoA.saveSection(Section(
      name: 'مشروبات',
      createdAt: now,
      updatedAt: now,
    ));
    final catId = await repoA.saveItemCategory(ItemCategory(
      name: 'غازيات',
      sectionId: secId,
      createdAt: now,
      updatedAt: now,
    ));
    final keepItemId = await repoA.saveItem(Item(
      name: 'بيبسي',
      categoryId: catId,
      sectionId: secId,
      sellPrice: 250,
      quantity: 20,
      createdAt: now,
      updatedAt: now,
    ));
    final lostItemId = await repoA.saveItem(Item(
      name: 'ميرندا',
      categoryId: catId,
      sectionId: secId,
      sellPrice: 250,
      quantity: 12,
      createdAt: now,
      updatedAt: now,
    ));

    // أخذ نسخة .nexora سليمة قبل الضرر
    final backupFile = File('${tmp.path}/before_join.nexora');
    await BackupEngine.createNexoraPackage(repoA, targetFile: backupFile);

    // محاكاة ضرر بعد انضمام عضو: حذف ميرندا نهائياً، تعديل رصيد بيبسي بفاتورة لاحقة (بيع 5)
    await dbA.delete('items', where: 'id = ?', whereArgs: [lostItemId]);
    await dbA.update(
      'items',
      {'quantity': 15.0},
      where: 'id = ?',
      whereArgs: [keepItemId],
    );
    await dbA.insert('accounts', {
      'id': 91,
      'workspace_id': repoA.requireWorkspaceId,
      'name': 'زبون الفاتورة اللاحقة',
      'kind': 'customer',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    await dbA.insert('transactions', {
      'id': 910,
      'workspace_id': repoA.requireWorkspaceId,
      'account_id': 91,
      'type': 'sale',
      'amount': 1250,
      'currency': 'YER',
      'date': now.toIso8601String(),
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    final result = await CatalogRecoveryService.restoreCatalogFromBackup(
      repoA,
      backupFile,
    );
    expect(result.restoredItems, 2);
    expect(result.restoredCategories, 1);
    expect(result.restoredSections, 1);

    // الصنف المفقود عاد
    final lostAfter =
        await dbA.query('items', where: 'id = ?', whereArgs: [lostItemId]);
    expect(lostAfter, hasLength(1));
    expect(lostAfter.single['name'], 'ميرندا');
    expect((lostAfter.single['quantity'] as num).toDouble(), 12.0);

    // الصنف القائم احتفظ برصيده الحي بعد الفاتورة اللاحقة (15 وليس 20)
    final keepAfter =
        await dbA.query('items', where: 'id = ?', whereArgs: [keepItemId]);
    expect((keepAfter.single['quantity'] as num).toDouble(), 15.0);

    // الفاتورة اللاحقة لم تُمس
    expect(await dbA.query('transactions', where: 'id = 910'), hasLength(1));
  });

  test(
      'BARRIER-01: SnapshotApply يحفظ جدول operations ويثبت atomic_sync_barrier لمنع إعادة تشغيل التاريخ وتضاعف المخزون ورأس المال حتى مع resetCursor: true',
      () async {
    const ws = 'WS-PY4WHH9S';
    const barrierMs = 1765000500000;
    await repoB.bindWorkspaceId(ws);

    // عملية مسجلة مسبقاً في جدول operations — يُحظر مسحها أثناء تطبيق اللقطة
    await dbB.insert('operations', {
      'id': 'pre-snap-op-1',
      'device_id': repoB.requireDeviceId,
      'workspace_id': ws,
      'entity_type': 'account',
      'entity_id': '10',
      'op_type': 'create',
      'payload': '{"id":10,"name":"عميل سابق"}',
      'version': 1,
      'parent_op_id': '',
      'device_time': now.toIso8601String(),
      'timestamp': now.toIso8601String(),
      'synced': 0,
      'is_synced': 0,
    });

    final snap = <String, Object?>{
      'workspaces': [
        {'id': ws, 'name': 'مركز عثمان الوصابي'}
      ],
      'items': [
        {
          'id': 7,
          'workspace_id': ws,
          'name': 'صنف نظيف بعد اللقطة',
          'buy_price': 1000.0,
          'sell_price': 1500.0,
          'quantity': 10.0,
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        }
      ],
      'accounts': [
        {
          'id': 1,
          'workspace_id': ws,
          'name': 'الصندوق الرئيسي',
          'kind': 'cash',
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        }
      ],
    };

    await SnapshotApply.applySnapshot(
      () async => dbB,
      repoB.requireDeviceId,
      snap,
      serverWatermarkMs: barrierMs,
    );

    // 1) التحقق من بقاء سجل operations مع وسمه كمُزامن وعدم حذفه
    final keptOps =
        await dbB.query('operations', where: 'id = ?', whereArgs: ['pre-snap-op-1']);
    expect(keptOps, hasLength(1));
    expect(keptOps.single['synced'], 1);

    // 2) التحقق من حفظ حاجز المزامنة الذري الصارم
    final barrierRow = (await dbB.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: ['atomic_sync_barrier:$ws'],
    ))
        .single;
    expect(barrierRow['value'], '$barrierMs');

    // 3) التحقق من أن السحب (حتى مع resetCursor: true و forceFullSync: true)
    // لا يسحب ولا يعيد تطبيق العمليات التاريخية الواقعة <= barrierMs، بينما يطبّق الأحدث فقط!
    final cloud = _AtomicMockCloud();
    cloud.store['/workspaces/$ws/operations/OP-HISTORICAL-OLD.json'] = {
      'id': 'OP-HISTORICAL-OLD',
      'device_id': 'DEV-HOST',
      'workspace_id': ws,
      'entity_type': 'stockMove',
      'entity_id': '801',
      'op_type': 'create',
      'version': 1,
      'parent_op_id': '',
      'payload': {
        'id': 801,
        'item_id': 7,
        'kind': 'purchase',
        'quantity': 20.0,
        'unit_price': 1000.0,
        'date': now.toIso8601String(),
      },
      'device_time': now.toIso8601String(),
      'timestamp': now.toIso8601String(),
      'server_time': barrierMs - 10000,
    };
    cloud.store['/workspaces/$ws/operations/OP-POST-BARRIER-NEW.json'] = {
      'id': 'OP-POST-BARRIER-NEW',
      'device_id': 'DEV-HOST',
      'workspace_id': ws,
      'entity_type': 'stockMove',
      'entity_id': '802',
      'op_type': 'create',
      'version': 1,
      'parent_op_id': '',
      'payload': {
        'id': 802,
        'item_id': 7,
        'kind': 'purchase',
        'quantity': 5.0,
        'unit_price': 1000.0,
        'date': now.toIso8601String(),
      },
      'device_time': now.toIso8601String(),
      'timestamp': now.toIso8601String(),
      'server_time': barrierMs + 5000,
    };

    final transport = CloudFirebaseTransport(
      repo: repoB,
      dbProvider: () async => dbB,
      backendUrl: url,
      workspaceId: ws,
    );
    final pulledCount = await http.runWithClient(
      () => transport.pull(
        resolver: ConflictResolver(),
        forceFullSync: true,
        resetCursor: true,
      ),
      cloud.client,
    );

    expect(pulledCount, 1);
    expect(await dbB.query('stock_moves', where: 'id = 801'), isEmpty);
    expect(await dbB.query('stock_moves', where: 'id = 802'), hasLength(1));

    // الكمية النهائية = 10 (اللقطة النظيفة) + 5 (الحركة الشرعية اللاحقة فقط) = 15 (وليس 35!)
    final item7 = (await dbB.query('items', where: 'id = 7')).single;
    expect((item7['quantity'] as num).toDouble(), 15.0);
  });
}
