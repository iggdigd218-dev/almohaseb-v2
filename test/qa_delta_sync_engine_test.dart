// اختبارات المزامنة الذكية التراكمية (Delta-Sync) وإيقاف هدر البيانات في Firebase RTDB:
// 1. استهلاك السحب بالمؤشر الزمني حصراً (Cursor-Based Inbound Sync: last_synced_cursor + server_time)
// 2. الرفع التراكمي للحركات غير المتزامنة فقط (Outbound Push Engine: is_synced == 0 -> ServerValue.TIMESTAMP -> is_synced = 1)
// 3. حظر تضمين الوسائط والبيانات الثقيلة (Base64 / صور الفواتير / وسائط الدردشة) داخل عقد operations
// 4. إيقاف اللقطات الشاملة والفحص العشوائي (No Full Dumps)
// 5. حل التعارضات بالاعتماد الحصري على وقت الخادم (server_time)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/auto_backup.dart';
import 'package:nexora_app/data/sync/cloud_firebase_transport.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/recorder.dart';
import 'package:nexora_app/data/sync/sync_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MockDeltaRtdbServer {
  final HttpServer _server;
  final Map<String, Map<String, Object?>> operations = {};
  final List<Uri> pullRequests = [];
  final List<Map<String, Object?>> pushPayloads = [];
  int backupPuts = 0;
  int nextServerTimeMs = 1760000000000;

  _MockDeltaRtdbServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<_MockDeltaRtdbServer> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _MockDeltaRtdbServer._(s);
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final bodyBytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    final bodyStr = utf8.decode(bodyBytes);

    if (path.endsWith('/backup.json') && req.method == 'PUT') {
      backupPuts++;
      req.response.statusCode = 200;
      req.response.write(bodyStr);
      await req.response.close();
      return;
    }

    // PUT /workspaces/{ws}/operations/{opId}.json
    final opMatch =
        RegExp(r'^/workspaces/[^/]+/operations/([^/]+)\.json$').firstMatch(path);
    if (opMatch != null && req.method == 'PUT') {
      final opId = Uri.decodeComponent(opMatch.group(1)!);
      final map = Map<String, Object?>.from(jsonDecode(bodyStr) as Map);
      pushPayloads.add(Map<String, Object?>.from(map));
      final resolvedNow = ++nextServerTimeMs;
      if (map['server_time'] is Map) {
        map['server_time'] = resolvedNow;
      }
      if (map['server_ts'] is Map) {
        map['server_ts'] = resolvedNow;
      }
      operations[opId] = map;
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(map));
      await req.response.close();
      return;
    }

    // GET /workspaces/{ws}/operations.json
    if (RegExp(r'^/workspaces/[^/]+/operations\.json$').hasMatch(path) &&
        req.method == 'GET') {
      pullRequests.add(req.uri);
      final qp = req.uri.queryParameters;
      final startAtRaw = qp['startAt'] ?? '0';
      final startAtNum = int.tryParse(startAtRaw.replaceAll('"', '')) ?? 0;
      final filtered = <String, Object?>{};
      for (final e in operations.entries) {
        final st = (e.value['server_time'] as int?) ??
            (e.value['server_ts'] as int?) ??
            0;
        if (st >= startAtNum) {
          filtered[e.key] = e.value;
        }
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(filtered));
      await req.response.close();
      return;
    }

    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write('null');
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Delta-Sync Engine & Bandwidth Optimization', () {
    test(
        'DELTA-01: استهلاك السحب بالمؤشر الزمني حصراً (last_synced_cursor + server_time) ومنع تكرار التنزيل',
        () async {
      final server = await _MockDeltaRtdbServer.start();
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEV-LOCAL-1');
      await repo.initSyncInfra();

      // عمليتان على السحابة من جهاز آخر بوقت خادم متسلسل
      final nowIso = DateTime.now().toIso8601String();
      server.operations['OP-REMOTE-1'] = {
        'id': 'OP-REMOTE-1',
        'device_id': 'DEV-REMOTE-9',
        'workspace_id': 'default',
        'entity_type': 'account',
        'entity_id': '101',
        'op_type': 'create',
        'version': 1,
        'parent_op_id': '',
        'payload': jsonEncode({
          'id': 101,
          'name': 'حساب دلتا 1',
          'created_at': nowIso,
          'updated_at': nowIso,
        }),
        'device_time': nowIso,
        'timestamp': nowIso,
        'server_time': 1760000001000,
        'server_ts': 1760000001000,
      };
      server.operations['OP-REMOTE-2'] = {
        'id': 'OP-REMOTE-2',
        'device_id': 'DEV-REMOTE-9',
        'workspace_id': 'default',
        'entity_type': 'account',
        'entity_id': '102',
        'op_type': 'create',
        'version': 1,
        'parent_op_id': '',
        'payload': jsonEncode({
          'id': 102,
          'name': 'حساب دلتا 2',
          'created_at': nowIso,
          'updated_at': nowIso,
        }),
        'device_time': nowIso,
        'timestamp': nowIso,
        'server_time': 1760000002500,
        'server_ts': 1760000002500,
      };

      final transport = CloudFirebaseTransport(
        repo: repo,
        dbProvider: () async => db,
        backendUrl: server.baseUrl,
        workspaceId: 'default',
      );

      final applied1 = await transport.pull();
      expect(applied1, 2);

      // التحقق من أن الطلب الأول مقيد بـ orderBy="server_time" وليس جلباً مفتوحاً
      expect(server.pullRequests, isNotEmpty);
      final firstQuery = server.pullRequests.first.queryParameters;
      expect(firstQuery['orderBy'], '"server_time"');
      expect(firstQuery.containsKey('startAt'), isTrue);

      // التحقق من تحديث المؤشر المحلي الدائم last_synced_cursor فوراً إلى أحدث server_time
      final savedCursor = await transport.getLastSyncedCursor();
      expect(savedCursor, 1760000002500);

      // دورة سحب ثانية بدون عمليات جديدة: تطلب startAfter (startAt = cursor + 1) ولا تعيد تنزيل السجلات السابقة
      server.pullRequests.clear();
      final applied2 = await transport.pull(forceFullSync: true);
      expect(applied2, 0);
      final secondQuery = server.pullRequests.first.queryParameters;
      expect(secondQuery['orderBy'], '"server_time"');
      expect(secondQuery['startAt'], '${1760000002500 + 1}',
          reason: 'يجب استئناف السحب بعد المؤشر الزمني حصراً حتى مع forceFullSync');

      await db.close();
      await server.close();
    });

    test(
        'DELTA-02: الرفع التراكمي للحركات غير المتزامنة فقط (is_synced == 0 -> ServerValue.TIMESTAMP -> is_synced = 1)',
        () async {
      final server = await _MockDeltaRtdbServer.start();
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEV-PUSH-1');
      await repo.setSetting('cloudBackendUrl', server.baseUrl);
      await repo.initSyncInfra();

      final rec = SyncRecorder(
        db: db,
        deviceId: 'DEV-PUSH-1',
        workspaceId: 'default',
      );
      final opId = await rec.record(
        entityType: EntityKind.account,
        entityId: '201',
        opType: OpKind.create,
        payload: {
          'id': 201,
          'name': 'عميل اختبار الرفع',
          'updated_at': DateTime.now().toIso8601String(),
        },
      );

      // قبل الرفع: is_synced == 0 في قاعدة SQLite المحلية
      final beforeRows =
          await db.query('operations', where: 'id = ?', whereArgs: [opId]);
      expect(beforeRows.first['is_synced'], 0);

      final queue = SyncQueueOps(db);
      final pending1 = await queue.pickPending(target: SyncTarget.cloud);
      expect(pending1.length, 1);

      final transport = CloudFirebaseTransport(
        repo: repo,
        dbProvider: () async => db,
        backendUrl: server.baseUrl,
        workspaceId: 'default',
      );
      final op = SyncOperation.fromMap(beforeRows.first);
      await transport.push(op);
      await queue.markSynced(pending1.first['id'] as int);

      // التحقق من إرسال server_time = ServerValue.TIMESTAMP ({'.sv': 'timestamp'})
      expect(server.pushPayloads.length, 1);
      expect(server.pushPayloads.first['server_time'], {'.sv': 'timestamp'});

      // بعد التأكيد: تحديث السجل محلياً إلى is_synced = 1 ومنع إعادة إرساله
      final afterRows =
          await db.query('operations', where: 'id = ?', whereArgs: [opId]);
      expect(afterRows.first['is_synced'], 1);
      expect(afterRows.first['synced'], 1);

      // حتى لو أُعيد إدراج صف في الطابور بالخطأ لن يُلتقط لأن is_synced == 1
      await transport.push(SyncOperation.fromMap(afterRows.first));
      expect(server.pushPayloads.length, 1,
          reason: 'يُمنع إعادة رفع سجل يحمل is_synced = 1');

      await db.close();
      await server.close();
    });

    test(
        'DELTA-03: حظر تضمين الوسائط والبيانات الثقيلة (صور الفواتير / Base64 / وسائط الدردشة) داخل عقد operations',
        () async {
      final server = await _MockDeltaRtdbServer.start();
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEV-MEDIA-1');
      await repo.initSyncInfra();

      final rec = SyncRecorder(
        db: db,
        deviceId: 'DEV-MEDIA-1',
        workspaceId: 'default',
      );
      final opId = await rec.record(
        entityType: EntityKind.tx,
        entityId: '301',
        opType: OpKind.create,
        payload: {
          'id': 301,
          'account_id': 1,
          'amount': 500,
          'details': 'فاتورة مبيعات نقدية',
          'image': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA',
          'file_b64': 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=',
          'photo_b64': 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=',
        },
      );

      final rows =
          await db.query('operations', where: 'id = ?', whereArgs: [opId]);
      final storedPayload =
          jsonDecode(rows.first['payload'] as String) as Map<String, Object?>;
      expect(storedPayload.containsKey('file_b64'), isFalse);
      expect(storedPayload.containsKey('photo_b64'), isFalse);
      expect(storedPayload['image'], '',
          reason: 'يجب تجريد صور الفواتير المضمّنة من عقد operations');
      expect(storedPayload['details'], 'فاتورة مبيعات نقدية');
      expect(storedPayload['amount'], 500);

      await db.close();
      await server.close();
    });

    test(
        'DELTA-04: إيقاف اللقطات الشاملة في الخلفية (No Full Dumps) وحسم التعارضات بوقت الخادم server_time',
        () async {
      final server = await _MockDeltaRtdbServer.start();
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEV-NODUMP-1');
      await repo.setSetting('cloudBackendUrl', server.baseUrl);
      await repo.initSyncInfra();

      // تشغيل مهمة الخلفية AutoBackupService.maybeRun لا يرفع أي لقطة كاملة إلى RTDB
      await AutoBackupService.maybeRun(repo);
      expect(server.backupPuts, 0,
          reason: 'يجب عدم رفع أي لقطة كاملة تلقائياً إلى RTDB في الخلفية');

      // اختبار حسم التعارضات بالاعتماد الحصري على server_time بغض النظر عن ساعة الجهاز المحلية
      final resolver = ConflictResolver();
      const incomingOp = SyncOperation(
        id: 'OP-CONFLICT-1',
        deviceId: 'DEV-B',
        workspaceId: 'default',
        userId: null,
        parentOpId: '',
        entityType: EntityKind.account,
        entityId: '10',
        opType: OpKind.update,
        version: 1,
        // ساعة جهاز DEV-B متأخرة محلياً لكن وقت الخادم server_time أحدث!
        deviceTime: '2020-01-01T00:00:00.000Z',
        timestamp: '2020-01-01T00:00:00.000Z',
        serverTime: '1760000099000',
        payload: {'id': 10, 'name': 'الاسم الأحدث حسب وقت الخادم'},
      );
      const localLatestOp = SyncOperation(
        id: 'OP-LOCAL-1',
        deviceId: 'DEV-A',
        workspaceId: 'default',
        userId: null,
        parentOpId: '',
        entityType: EntityKind.account,
        entityId: '10',
        opType: OpKind.update,
        version: 5,
        deviceTime: '2026-01-01T00:00:00.000Z',
        timestamp: '2026-01-01T00:00:00.000Z',
        serverTime: '1760000010000',
        payload: {'id': 10, 'name': 'الاسم القديم'},
      );

      final decision = resolver.decide(
        incoming: incomingOp,
        exists: true,
        localVersion: 5, // حتى لو كان الإصدار المحلي أكبر
        localLatest: localLatestOp, // ووقت الخادم المحلي أقدم
      );
      expect(decision.apply, isTrue,
          reason: 'يجب حسم التعارض لصالح العملية ذات وقت الخادم server_time الأحدث حصرياً');

      await db.close();
      await server.close();
    });
  });
}
