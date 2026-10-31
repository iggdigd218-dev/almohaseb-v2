// QA — دفعة 58 المرحلة 6 (متطلب 21): اختبار تكاملي شامل بعد اجتثاث LAN:
// - المزامنة سحابية-فقط تعمل بين جهازين (حساب + عملية مالية تصل كاملة).
// - النسخ الاحتياطي والاسترجاع (محلي + سحابي برمز) يعملان.
// - لا بقايا LAN في الشيفرة (منفذ 43053 / lan_http) ولا في المخطط.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/sync/auto_backup.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_firebase_transport.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';

/// سحابة وهمية موحّدة: عمليات تزايدية + نسخ كاملة برمز + روستر الأجهزة.
class _FakeCloud {
  final Map<String, Map<String, Object?>> operations = {};
  final Map<String, Map<String, Object?>> roster = {};
  Map<String, Object?>? codeRecord;
  int _nextServerTime = 1760000100000;

  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        final path = req.url.path;
        if (path.contains('/codes/')) {
          if (req.method == 'PUT') {
            codeRecord =
                Map<String, Object?>.from(jsonDecode(req.body) as Map);
            return _json(req.body, 200);
          }
          return _json(
              codeRecord == null ? 'null' : jsonEncode(codeRecord), 200);
        }
        if (path.contains('/roster/')) {
          final devId = Uri.decodeComponent(
              path.split('/roster/').last.replaceAll('.json', ''));
          if (req.method == 'PUT') {
            final map = Map<String, Object?>.from(jsonDecode(req.body) as Map);
            roster[devId] = map;
            return _json(jsonEncode(map), 200);
          }
          if (req.method == 'PATCH') {
            final patch =
                Map<String, Object?>.from(jsonDecode(req.body) as Map);
            final existing = roster[devId] ?? <String, Object?>{'id': devId};
            existing.addAll(patch);
            roster[devId] = existing;
            return _json(jsonEncode(existing), 200);
          }
          final item = roster[devId];
          return _json(item == null ? 'null' : jsonEncode(item), 200);
        }
        if (path.endsWith('/roster.json')) {
          if (roster.isEmpty) return _json('null', 200);
          return _json(jsonEncode(roster), 200);
        }
        if (path.contains('/operations')) {
          if (req.method == 'PUT') {
            final opId = Uri.decodeComponent(
                path.split('/operations/').last.replaceAll('.json', ''));
            final map = Map<String, Object?>.from(jsonDecode(req.body) as Map);
            final serverTs = ++_nextServerTime;
            if (map['server_time'] is Map) map['server_time'] = serverTs;
            if (map['server_ts'] is Map) map['server_ts'] = serverTs;
            operations[opId] = map;
            return _json(jsonEncode(map), 200);
          }
          if (operations.isEmpty) return _json('null', 200);
          return _json(jsonEncode(operations), 200);
        }
        return _json('null', 200);
      });
}

void main() {
  // هذه الحزمة تبني فرضياتها على مسار workspaces/default القديم —
  // نثبّت المعرف القديم بدل التوليد العشوائي (المعمارية الصامتة).
  debugForceLegacyWorkspaceId = true;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime(2026, 9, 12);
  const url = 'https://qa-b58.firebaseio.com';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_b58_e2e_');
    Future<Database> open(String name) =>
        databaseFactory.openDatabase('${tmp.path}/$name.db',
            options: OpenDatabaseOptions(
                onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
    a = await open('a');
    b = await open('b');
    await AppDatabase.createSchema(a);
    await AppDatabase.createSchema(b);
    repoA = Repo(databaseProvider: () async => a);
    repoB = Repo(databaseProvider: () async => b);
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
  });
  tearDown(() async {
    if (a.isOpen) await a.close();
    if (b.isOpen) await b.close();
    await tmp.delete(recursive: true);
  });

  CloudFirebaseTransport transport(Repo repo, Database db) =>
      CloudFirebaseTransport.validated(
        repo: repo,
        dbProvider: () async => db,
        backendUrl: url,
        workspaceId: 'default',
      );

  test('B58-E2E-01 cloud-only sync: account + transaction flow A → cloud → B',
      () async {
    final cloud = _FakeCloud();
    // المدير أ يسجّل حساباً وعملية مالية.
    final accId = await repoA.saveAccount(Account(
      name: 'عميل التكامل 58',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await repoA.saveTx(Tx(
      accountId: accId,
      accountKind: AccountKind.customer,
      type: OpType.debit,
      amount: 750,
      currency: 'YER',
      sign: '+',
      fromId: null,
      toId: null,
      rate: 1,
      description: 'دين تكاملي',
      reference: '',
      notes: '',
      category: '',
      attachment: '',
      attachmentHash: '',
      image: '',
      status: 'done',
      syncState: 'pending',
      date: now,
      createdAt: now,
      updatedAt: now,
    ));
    // دفع كل العمليات المسجلة إلى السحابة (القناة الوحيدة).
    final tA = transport(repoA, a);
    final pending = await a.query('operations', where: 'synced = 0');
    expect(pending.length, greaterThanOrEqualTo(2),
        reason: 'حساب + عملية مالية على الأقل');
    for (final row in pending) {
      await http.runWithClient(
          () => tA.push(SyncOperation.fromMap(row)), cloud.client);
    }
    // الجهاز ب يسحب فيتبنى كل شيء.
    final tB = transport(repoB, b);
    final applied = await http.runWithClient(
        () => tB.pull(resolver: ConflictResolver()), cloud.client);
    expect(applied, greaterThanOrEqualTo(2));
    final bAcc = await b
        .query('accounts', where: 'id = ?', whereArgs: [accId], limit: 1);
    expect(bAcc, isNotEmpty);
    expect(bAcc.first['name'], 'عميل التكامل 58');
    final bTx = await b.query('transactions',
        where: 'account_id = ?', whereArgs: [accId]);
    expect(bTx, hasLength(1));
    expect(bTx.first['amount'], 750);
    // التحقق الصارم: العملية الواردة من السحابة تُحفظ على هاتف العضو بحالة synced فوراً
    // ولا تدخل طابور الرفع المحلي sync_queue.
    expect(bTx.first['sync_state'], 'synced',
        reason: 'العملية الواردة من السحابة يجب أن تحمل sync_state = synced لدى العضو');
    final bQueue = await b.query('sync_queue');
    expect(bQueue, isEmpty,
        reason: 'العملية الواردة من السحابة لا يجوز إدراجها في طابور الرفع المحلي');
    // سحب ثانٍ idempotent.
    final again = await http.runWithClient(
        () => tB.pull(resolver: ConflictResolver()), cloud.client);
    expect(again, 0);
  });

  test('B58-E2E-02 backup: local export/import + silent workspace backup',
      () async {
    // (3.70) مسار النسخ الوحيد: AutoBackupService (النسخة الصامتة لمسار
    // المساحة) — بديل خدمة cloud_sync الرمزية القديمة المجتثة.
    await repoA.setSetting('cloudBackendUrl', url);
    // (2026-09-22) بوابة جوجل: النسخ السحابي يتطلب حساباً مربوطاً.
    await repoA.setSetting('account.email', 'boss58@nexora.test');
    await repoA.saveAccount(Account(
      name: 'حساب النسخة 58',
      kind: AccountKind.supplier,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    // نسخة محلية.
    final local = await repoA.exportForLocalBackup();
    expect(local['app'], 'nexora');
    // نسخة كاملة إلى السحابة الخاصة (مسار المساحة) ثم سحبها.
    final store = <String, Object?>{};
    http.Response js(Object? v) => http.Response.bytes(
        utf8.encode(v == null ? 'null' : jsonEncode(v)), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    final client = MockClient((req) async {
      if (req.method == 'PUT') {
        store[req.url.path] = jsonDecode(req.body);
        return js(store[req.url.path]);
      }
      return js(store[req.url.path]);
    });
    final ok = await http.runWithClient(
        () => AutoBackupService.silentWorkspaceBackup(repoA), () => client);
    expect(ok, isTrue);
    final pulled = await http.runWithClient(
        () => AutoBackupService.pullWorkspaceBackup(repoA,
            backendUrl: url, workspaceId: repoA.requireWorkspaceId),
        () => client);
    expect(pulled, isNotNull);
    // الاسترجاع في نفس المجموعة يُقبل ويعيد البيانات.
    // pullWorkspaceBackup يعيد حمولة exportAll نفسها (بلا غلاف).
    final restored =
        await repoA.importAll(Map<String, Object?>.from(pulled!));
    expect(restored, greaterThan(0));
    final accs = await repoA.accounts();
    expect(accs.map((x) => x.name), contains('حساب النسخة 58'));
  });

  test('B58-E2E-03 zero LAN residue: no port 43053 / lan_http in lib, '
      'no LAN artifacts in schema', () async {
    // مسح مصدري: لا منفذ LAN ولا ناقل lan_http في lib/.
    final libDir = Directory('lib');
    final offenders = <String>[];
    for (final f in libDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      if (src.contains('43053') || src.contains('lan_http')) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'بقايا LAN في: ${offenders.join('، ')}');
    // المخطط: لا op_deliveries ولا أعمدة ip/port.
    final t = await a.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='op_deliveries'");
    expect(t, isEmpty);
    final cols = await a.rawQuery('PRAGMA table_info(devices)');
    final names = cols.map((c) => '${c['name']}').toSet();
    expect(names.contains('ip_address'), isFalse);
    expect(names.contains('port'), isFalse);
    // الاستعلامات الأساسية سليمة (لا أعمدة مفقودة).
    await repoA.transactions();
    await repoA.accounts();
    await repoA.users();
  });

  test(
      'B58-E2E-04 Manager Sync Monitor: pull PATCHes last_synced_time in roster, '
      'syncRoster updates local devices, and txDeliveryBadgesProvider tracks 1/3 -> 2/3 -> 3/3',
      () async {
    final cloud = _FakeCloud();
    final mgrId = repoA.requireDeviceId;
    final mem1Id = repoB.requireDeviceId;
    const mem2Id = 'DEV-MEMBER-C';

    // إعداد جهاز ب كعضو فعلي، وإضافة العضوين في جدول devices لدى المدير أ
    await b.update('devices', {'is_owner': 0, 'is_paired': 1},
        where: 'id = ?', whereArgs: [mem1Id]);
    await b.insert(
      'sync_meta',
      {'key': 'workspaceMode', 'value': 'member'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final initIso = now.toIso8601String();
    cloud.roster[mgrId] = {
      'id': mgrId,
      'workspace_id': 'default',
      'name': 'جهاز المدير',
      'is_paired': 1,
      'is_owner': 1,
      'revoked_at': '',
      'expelled_at': '',
      'updated_at': initIso,
    };
    for (final entry in [
      {'id': mem1Id, 'name': 'جهاز عضو 1'},
      {'id': mem2Id, 'name': 'جهاز عضو 2'},
    ]) {
      await a.insert(
        'devices',
        {
          'id': entry['id'],
          'workspace_id': 'default',
          'name': entry['name'],
          'is_paired': 1,
          'is_owner': 0,
          'revoked_at': '',
          'expelled_at': '',
          'last_sync_at': '',
          'created_at': initIso,
          'updated_at': initIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      cloud.roster[entry['id']!] = {
        'id': entry['id'],
        'workspace_id': 'default',
        'name': entry['name'],
        'is_paired': 1,
        'is_owner': 0,
        'revoked_at': '',
        'expelled_at': '',
        'updated_at': initIso,
      };
    }

    // المدير أ ينشئ عملية مالية ويرفعها للسحابة
    final accId = await repoA.saveAccount(Account(
      name: 'عميل تتبع الانتشار',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    final txId = await repoA.saveTx(Tx(
      accountId: accId,
      accountKind: AccountKind.customer,
      type: OpType.revenue,
      amount: 1200,
      currency: 'YER',
      sign: '+',
      rate: 1,
      description: 'فاتورة مراقب الانتشار',
      status: 'done',
      syncState: 'pending',
      date: now,
      createdAt: now,
      updatedAt: now,
    ));

    final tA = transport(repoA, a);
    final pending = await a.query('operations', where: 'synced = 0');
    for (final row in pending) {
      await http.runWithClient(
          () => tA.push(SyncOperation.fromMap(row)), cloud.client);
    }
    await a.update('transactions', {'sync_state': 'synced'},
        where: 'id = ?', whereArgs: [txId]);

    // 1) قبل سحب أي عضو: العداد لدى المدير 1/3 (المدير فقط استلمها)
    final containerA = ProviderContainer(overrides: [
      repoProvider.overrideWithValue(repoA),
    ]);
    addTearDown(containerA.dispose);

    var badgesA = await containerA.read(txDeliveryBadgesProvider.future);
    expect(badgesA['$txId']?.delivered, 1);
    expect(badgesA['$txId']?.total, 3);
    expect(badgesA['$txId']?.all, isFalse);

    // بينما على جهاز العضو ب: العزل التام يعيد خريطة فارغة بلا عدادات
    final containerB = ProviderContainer(overrides: [
      repoProvider.overrideWithValue(repoB),
    ]);
    addTearDown(containerB.dispose);
    final badgesB = await containerB.read(txDeliveryBadgesProvider.future);
    expect(badgesB, isEmpty,
        reason: 'أجهزة الأعضاء معزولة تماماً عن عدادات ومراقب انتشار الأجهزة الأخرى');

    // 2) العضو 1 يسحب العملية -> يحدث PATCH تلقائي لـ last_synced_time في الروستر السحابي
    final tB = transport(repoB, b);
    await http.runWithClient(
        () => tB.pull(resolver: ConflictResolver()), cloud.client);
    expect(cloud.roster[mem1Id]?['last_synced_time'], isNotNull,
        reason: 'pull لدى العضو يجب أن يحدث last_synced_time في عقدته بالروستر');

    // المدير يزامن الروستر -> يلتقط last_synced_time للعضو 1 -> العداد يصبح 2/3
    await http.runWithClient(
      () => CloudJoin.syncRoster(
        repoA,
        a,
        backendUrl: url,
        workspaceId: 'default',
      ),
      cloud.client,
    );
    containerA.invalidate(txDeliveryBadgesProvider);
    badgesA = await containerA.read(txDeliveryBadgesProvider.future);
    expect(badgesA['$txId']?.delivered, 2);
    expect(badgesA['$txId']?.total, 3);
    expect(badgesA['$txId']?.all, isFalse);

    // 3) العضو 2 يحدث مؤشر مزامنته في الروستر -> العداد لدى المدير يصبح 3/3 مكتمل (all = true)
    cloud.roster[mem2Id]!['last_synced_time'] =
        cloud.roster[mem1Id]!['last_synced_time'];
    await http.runWithClient(
      () => CloudJoin.syncRoster(
        repoA,
        a,
        backendUrl: url,
        workspaceId: 'default',
      ),
      cloud.client,
    );
    containerA.invalidate(txDeliveryBadgesProvider);
    badgesA = await containerA.read(txDeliveryBadgesProvider.future);
    expect(badgesA['$txId']?.delivered, 3);
    expect(badgesA['$txId']?.total, 3);
    expect(badgesA['$txId']?.all, isTrue);
  });

  test('B58-E2E-05 pos checkout: account selection hidden in cash mode and clean customer labels', () {
    final posSrc = File('lib/ui/pos_screen.dart').readAsStringSync();
    expect(posSrc.contains('عميل نقدي (بدون حساب)'), isFalse,
        reason: 'يجب إزالة عبارة عميل نقدي (بدون حساب) من نافذة الدفع');
    expect(posSrc.contains("child: Text('بيع نقدي')"), isTrue,
        reason: 'يجب اعتماد تسمية بيع نقدي في نافذة الدفع');
    expect(posSrc.contains('بدون هاتف'), isFalse,
        reason: 'يجب إزالة رقم الهاتف والأقواس من القائمة المنسدلة للعملاء');
    expect(posSrc.contains('if (needsAccount) ...['), isTrue,
        reason: 'يجب عدم إظهار خيارات اختيار حساب العميل إلا عند تحديد العملية آجل/جزئي');
  });
}
