// طبقة Firebase Realtime Database (REST) للمزامنة السحابية التزايدية (Production-hardened).
//
// التطويرات عن النسخة السابقة:
//  - سحب تزايدي (incremental pull) باستخدام sync_meta.lastCloudOpId بدل آخر 500 عملية فقط.
//  - إرسال auth=<idToken> مع كل طلب: حساب Google إن وُجد، وإلا هوية
//    الجهاز المجهولة (المرحلة 2) — فلا طلب بلا مصادقة بعد اليوم.
//  - تحقق HTTPS فقط (رفض http).
//  - validation لـ URL.
//  - استخدام startAfter لـ pagination عند تجاوز الدفعات.
//  - لا نعتمد على ترتيب السيرفر فقط؛ نحتفظ cursor محلي.
//  - استماع فوري SSE: قناة مفتوحة تُخطرنا لحظة وصول أي عملية جديدة
//    (المزامنة تصبح شبه فورية بدل انتظار السحب الدوري).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/desktop_net.dart';
import '../repository.dart';
import 'apply_remote.dart';
import 'conflict_resolver.dart';
import 'device_id.dart';
import 'firebase_auth_service.dart';
import 'chat_hooks.dart';
import 'operation.dart';
import 'sync_engine.dart';

class CloudFirebaseTransport implements SyncTransport {
  final Repo repo;
  final String backendUrl;
  final String workspaceId;
  final Future<Database> Function() _dbProvider;
  final Future<String?> Function() _idTokenProvider;
  static const int kPullPageSize = 500;

  CloudFirebaseTransport({
    required this.repo,
    required Future<Database> Function() dbProvider,
    required this.backendUrl,
    required this.workspaceId,
    Future<String?> Function()? idTokenProvider,
  })  : _dbProvider = dbProvider,
        _idTokenProvider = idTokenProvider ?? (() async => null);

  factory CloudFirebaseTransport.validated({
    required Repo repo,
    required Future<Database> Function() dbProvider,
    required String backendUrl,
    required String workspaceId,
    Future<String?> Function()? idTokenProvider,
  }) {
    final trimmed = backendUrl.trim();
    if (trimmed.isEmpty) throw ArgumentError('backendUrl فارغ');
    final u = Uri.tryParse(trimmed);
    if (u == null || !u.hasScheme || !u.isScheme('https')) {
      throw ArgumentError('رابط Firebase يجب أن يبدأ بـ https://');
    }
    if (!u.host.contains('firebaseio.com') &&
        !u.host.contains('firebasedatabase.app')) {
      // نقبل أيضًا روابط مخصصة ولكن مع تحذير ضمني — نسمح لمرونة التطوير.
    }
    return CloudFirebaseTransport(
      repo: repo,
      dbProvider: dbProvider,
      backendUrl: trimmed,
      workspaceId: workspaceId,
      idTokenProvider: idTokenProvider,
    );
  }

  Future<Database> get _db => _dbProvider();

  @override
  String get targetId => SyncTarget.cloud;

  String get _root =>
      '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(workspaceId)}';

  String _opPath(String opId) =>
      '$_root/operations/${Uri.encodeComponent(opId)}.json';
  /// مسار الاستماع SSE — بالصيغة القياسية المعتمدة للنطاق الإقليمي:
  ///   `$baseUrl/workspaces/$workspaceId/operations.json`
  /// baseUrl يصل مُطبَّعاً بلا شرطة نهائية (effectiveBackendUrl) —
  /// شرطة مكررة قبل /workspaces كانت تُنتج 404 (sse-http-404) على نطاق
  /// firebasedatabase.app الإقليمي، و_root يزيل أي بقايا احتياطاً.
  String get _opsPath => '$_root/operations.json';

  Map<String, String> get _authHeaders {
    return {'Content-Type': 'application/json'};
  }

  // (دفعة 57) تتبع انتهاء صلاحية JWT استباقياً: نفك حقل exp من التوكن
  // ونرفض إرفاق توكن منتهٍ (أو على وشك الانتهاء خلال 60 ثانية) بدل
  // إهدار طلب كامل ينتظر 401/403 ثم يُعاد. نتيجة الفك مُخبأة لكل توكن.
  String? _expCachedToken;
  int _expCachedMs = 0;

  static int jwtExpiryMs(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return 0;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (payload.length % 4 != 0) {
        payload += '=';
      }
      final m = jsonDecode(utf8.decode(base64Decode(payload)));
      if (m is! Map) return 0;
      final exp = (m['exp'] as num?)?.toInt() ?? 0;
      return exp * 1000;
    } catch (_) {
      return 0;
    }
  }

  Future<String?> _idToken() async {
    final tok = await _idTokenProvider();
    if (tok != null && tok.isNotEmpty) {
      if (!identical(tok, _expCachedToken) && tok != _expCachedToken) {
        _expCachedToken = tok;
        _expCachedMs = jwtExpiryMs(tok);
      }
      final expired = _expCachedMs > 0 &&
          DateTime.now().millisecondsSinceEpoch > _expCachedMs - 60000;
      if (!expired) return tok;
      // توكن Google منتهٍ/يوشك → نُكمل للهوية المجهولة أدناه.
    }
    // (المرحلة 2) لا حساب Google (أو توكنه منتهٍ) → توكن هوية الجهاز
    // المجهولة: يضمن أن كل طلب يحمل auth.uid، فتعمل قواعد الأمان.
    return FirebaseAuthRest.cloudIdToken();
  }

  /// رمز وقت الخادم في Firebase RTDB REST API (ServerValue.TIMESTAMP).
  static const Map<String, String> kServerValueTimestamp = {'.sv': 'timestamp'};

  /// يقرأ المؤشر الزمني المحلي الدائم `last_synced_cursor` (بالملي ثانية من `server_time`).
  /// يدعم التوافق الخلفي مع المفتاح القديم `lastCloudTs:$workspaceId` وصيغ ISO.
  Future<int> getLastSyncedCursor() async {
    final db = await _db;
    final rows = await db.query(
      'sync_meta',
      where: 'key IN (?, ?)',
      whereArgs: [
        'last_synced_cursor:$workspaceId',
        'lastCloudTs:$workspaceId',
      ],
    );
    int best = 0;
    for (final r in rows) {
      final raw = '${r['value'] ?? ''}'.trim();
      final parsed = int.tryParse(raw) ??
          (DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0);
      if (parsed > best) best = parsed;
    }
    if (best > 0) return best;
    try {
      final stRows = await db.query(
        'settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['last_synced_cursor'],
        limit: 1,
      );
      if (stRows.isNotEmpty) {
        final raw = '${stRows.first['value'] ?? ''}'.trim();
        final parsed = int.tryParse(raw) ??
            (DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0);
        if (parsed > best) best = parsed;
      }
    } catch (_) {}
    return best;
  }

  /// يحفظ المؤشر الزمني المحلي الدائم `last_synced_cursor` فوراً لمنع تكرار التنزيل.
  Future<void> saveLastSyncedCursor(
    int cursorMs, {
    DatabaseExecutor? executor,
  }) async {
    if (cursorMs <= 0) return;
    final target = executor ?? await _db;
    await target.insert(
      'sync_meta',
      {
        'key': 'last_synced_cursor:$workspaceId',
        'value': '$cursorMs',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await target.insert(
      'sync_meta',
      {
        'key': 'lastCloudTs:$workspaceId',
        'value': '$cursorMs',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    try {
      await target.insert(
        'settings',
        {
          'key': 'last_synced_cursor',
          'value': '$cursorMs',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  /// يبني معاملات استعلام الاستئناف الحصري بالمؤشر الزمني:
  /// `.orderByChild('server_time').startAfter(last_synced_cursor)`
  /// في واجهة REST يقابل `orderBy="server_time"&startAt=${last_synced_cursor + 1}`.
  static Map<String, String> buildCursorQueryParams({
    required int lastSyncedCursor,
    String indexField = 'server_time',
    int limit = kPullPageSize,
    bool forRealtimeStream = false,
  }) {
    final startAfterCursor = lastSyncedCursor > 0 ? lastSyncedCursor + 1 : 0;
    return <String, String>{
      'orderBy': jsonEncode(indexField),
      'startAt': '$startAfterCursor',
      if (forRealtimeStream)
        'limitToLast': '1'
      else
        'limitToFirst': '$limit',
    };
  }

  @override
  Future<void> push(SyncOperation op) async {
    final db = await _db;
    // 1. حصر عمليات الرفع على السجلات التي تحمل الوسم `is_synced == 0` في SQLite.
    try {
      final existingRows = await db.query(
        'operations',
        columns: ['is_synced', 'synced'],
        where: 'id = ?',
        whereArgs: [op.id],
        limit: 1,
      );
      if (existingRows.isNotEmpty) {
        final isSynced = (existingRows.first['is_synced'] as int?) ?? 0;
        final synced = (existingRows.first['synced'] as int?) ?? 0;
        if (isSynced == 1 || synced == 1) {
          return; // مرفوعة ومؤكدة مسبقاً — يُمنع إعادة إرسالها في أي دورة لاحقة.
        }
      }
    } on DatabaseException catch (_) {}

    final uri = Uri.parse(_opPath(op.id));
    // 2. حظر تضمين الوسائط والبيانات الثقيلة (Base64 / صور الفواتير / وسائط الدردشة)
    // داخل عقد operations، ورفع العملية كحركة إلحاقية مفردة (Atomic Append)
    // مع وسم `server_time = ServerValue.TIMESTAMP`.
    final sanitizedPayload = sanitizeOperationPayload(
      op.payload,
      entityType: op.entityType,
      entityId: op.entityId,
    );
    final rawMap = Map<String, Object?>.from(jsonDecode(op.toJson()) as Map)
      ..['payload'] = jsonEncode(sanitizedPayload)
      ..['server_time'] = kServerValueTimestamp
      ..['server_ts'] = kServerValueTimestamp
      ..['is_synced'] = 1
      ..['synced'] = 1;
    final body = jsonEncode(rawMap);
    final token = await _idToken();
    final auth =
        token == null ? null : 'auth=${Uri.encodeQueryComponent(token)}';
    final targetUri = auth == null ? uri : uri.replace(query: auth);
    var res = await http
        .put(targetUri, body: body, headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    if ((res.statusCode == 401 || res.statusCode == 403) && token != null) {
      // (المرحلة 2) إعادة المحاولة **بلا مصادقة** أُلغيت نهائياً: القواعد
      // تشترط `auth != null`، والطلب العاري كان يخفي غياب الهوية فقط
      // (ثغرة أ-1). الآن: نجدّد توكن الجهاز ونعيد المحاولة مرة واحدة.
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh != token) {
        res = await http
            .put(
              uri.replace(query: 'auth=${Uri.encodeComponent(fresh)}'),
              body: body,
              headers: _authHeaders,
            )
            .timeout(const Duration(seconds: 10));
      }
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw StateError('cloud-auth-failed: ${res.statusCode}');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('cloud-http-${res.statusCode}');
    }

    // استخلاص وقت الخادم الفعلي المعاد من Firebase بعد حل ServerValue.TIMESTAMP
    String resolvedServerTime = '${DateTime.now().millisecondsSinceEpoch}';
    try {
      final respDecoded = jsonDecode(res.body);
      if (respDecoded is Map) {
        final st = respDecoded['server_time'] ?? respDecoded['server_ts'];
        if (st is int && st > 0) {
          resolvedServerTime = '$st';
        } else if (st is num && st > 0) {
          resolvedServerTime = '${st.toInt()}';
        }
      }
    } catch (_) {}

    // 3. بمجرد استلام رد التأكيد بالنجاح، يتم تحديث السجل محلياً إلى `is_synced = 1`
    // ومنع إعادة إرساله في أي دورة مزامنة لاحقة.
    try {
      await db.update(
        'operations',
        {
          'server_time': resolvedServerTime,
          'synced': 1,
          'is_synced': 1,
          'payload': jsonEncode(sanitizedPayload),
        },
        where: 'id = ?',
        whereArgs: [op.id],
      );
    } on DatabaseException catch (_) {
      await db.update(
        'operations',
        {
          'server_time': resolvedServerTime,
          'synced': 1,
          'payload': jsonEncode(sanitizedPayload),
        },
        where: 'id = ?',
        whereArgs: [op.id],
      );
    }
    await db.update(
      'devices',
      {'last_sync_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [op.deviceId],
    );

    // تسجيل شواهد القبور في السحابة عند حذف صنف لضمان عدم إحيائه على الأجهزة المنضمة
    if (op.entityType == EntityKind.item && op.opType == OpKind.delete_) {
      try {
        final tombUri = Uri.parse(
            '$_root/deleted_items/${Uri.encodeComponent(op.entityId)}.json');
        final targetTombUri =
            auth == null ? tombUri : tombUri.replace(query: auth);
        final tombBody = jsonEncode({
          'id': op.entityId,
          'is_deleted': 1,
          'deleted_at': op.deviceTime.isNotEmpty
              ? op.deviceTime
              : DateTime.now().toIso8601String(),
          'server_time': kServerValueTimestamp,
          'server_ts': kServerValueTimestamp,
        });
        await http
            .put(targetTombUri, body: tombBody, headers: _authHeaders)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  // ==================== المصافحة النشطة للسجل (دفعة 53) ====================
  // الجهاز يتحقق بنفسه من عضويته في /roster/$deviceId — الطرد يُكتشف حتى
  // لو حُذفت عقدته نهائياً (وليس فقط عند وسمها revoked/expelled).

  /// يُستدعى عند اكتشاف أن هذا الجهاز طُرد/حُذف من سجل المجموعة.
  /// تبديل فحص المفاتيح الأجنبية (خارج المعاملات فقط — PRAGMA داخل
  /// معاملة لا أثر له في SQLite).
  Future<void> _setForeignKeys(bool enabled) async {
    try {
      await (await _db)
          .execute('PRAGMA foreign_keys = ${enabled ? 'ON' : 'OFF'}');
    } catch (_) {}
  }

  Future<int> pull({ConflictResolver? resolver, bool forceFullSync = false}) async {
    final db = await _db;
    // استهلاك السحب بالمؤشر الزمني حصراً (Cursor-Based Inbound Sync):
    // نقرأ المؤشر المحلي الدائم `last_synced_cursor` المعتمد على `server_time`.
    // يُمنع أي استعلام مفتوح يجلب كامل مسار العمليات `/workspaces/{ws}/operations`.
    final int lastCursorMs = await getLastSyncedCursor();
    final r = resolver ?? ConflictResolver();
    int applied = 0;
    int maxTsMs = lastCursorMs;
    int droppedOtherWs = 0;
    String droppedSample = '';
    final ourId = await ensureDeviceId(repo);
    final chatOps = <SyncOperation>[];
    final roleOps = <SyncOperation>[];
    final ownershipOps = <SyncOperation>[];

    bool hasMore = true;
    int currentCursorMs = lastCursorMs;
    String indexField = 'server_time';
    while (hasMore) {
      // حصر الاستعلام بالاستئناف فقط: .orderByChild('server_time').startAfter(last_synced_cursor)
      final params = buildCursorQueryParams(
        lastSyncedCursor: currentCursorMs,
        indexField: indexField,
        limit: kPullPageSize,
      );
      final tok = await _idToken();
      if (tok != null) params['auth'] = tok;
      final uri = Uri.parse(_opsPath).replace(queryParameters: params);
      var res = await http.get(uri).timeout(const Duration(seconds: 15));
      if ((res.statusCode == 401 || res.statusCode == 403) && tok != null) {
        final fresh = await FirebaseAuthRest.forceRefreshToken();
        if (fresh != null && fresh != tok) {
          params['auth'] = fresh;
          final retried =
              Uri.parse(_opsPath).replace(queryParameters: params);
          res = await http.get(retried).timeout(const Duration(seconds: 15));
        }
      }
      // توافق خلفي إذا كانت القواعد السحابية مفهرسة على server_ts بدلاً من server_time:
      // لا نسقط أبداً إلى جلب كامل مفتوح بدون مؤشر (No Full Dumps).
      if (res.statusCode == 400 && indexField == 'server_time') {
        indexField = 'server_ts';
        final fallbackParams = buildCursorQueryParams(
          lastSyncedCursor: currentCursorMs,
          indexField: indexField,
          limit: kPullPageSize,
        );
        if (tok != null) fallbackParams['auth'] = tok;
        final fallbackUri =
            Uri.parse(_opsPath).replace(queryParameters: fallbackParams);
        res = await http.get(fallbackUri).timeout(const Duration(seconds: 15));
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw StateError('cloud-auth-failed');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('cloud-http-${res.statusCode}');
      }
      if (res.body.trim().isEmpty || res.body.trim() == 'null') {
        hasMore = false;
        break;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded.isEmpty) {
        hasMore = false;
        break;
      }
      var entries = decoded.entries.toList();
      // وقت العملية للمؤشر/الترشيح: يعتمد حصرياً على وقت الخادم المرجعي `server_time`
      // (مع توافق خلفي لـ `server_ts` و `timestamp` للسجلات القديمة).
      int entryMs(Object? v) {
        if (v is! Map) return 0;
        final st = v['server_time'] ?? v['server_ts'];
        if (st is int && st > 0) return st;
        if (st is num && st > 0) return st.toInt();
        if (st is String && st.isNotEmpty) {
          final parsed = int.tryParse(st) ??
              (DateTime.tryParse(st)?.millisecondsSinceEpoch ?? 0);
          if (parsed > 0) return parsed;
        }
        return DateTime.tryParse('${v['timestamp'] ?? ''}')
                ?.millisecondsSinceEpoch ??
            0;
      }

      // تصفية محلية إضافية صارمة: استئناف ما بعد `currentCursorMs` فقط (startAfter)
      if (currentCursorMs > 0) {
        entries =
            entries.where((e) => entryMs(e.value) > currentCursorMs).toList();
      }
      if (entries.isEmpty) {
        hasMore = false;
        break;
      }

      // فرز محلي حسب وقت الخادم (server_time) ثم opId لضمان الترتيب
      entries.sort((a, b) {
        final va = a.value;
        final vb = b.value;
        if (va is! Map || vb is! Map) return 0;
        final c = entryMs(va).compareTo(entryMs(vb));
        return c != 0 ? c : (a.key as String).compareTo(b.key as String);
      });
      // فرز حسب التبعية قبل التطبيق (حسابات ← أصناف ← فواتير ← بنود)
      entries.sort((a, b) {
        final c = dependencyRankOfMap(a.value)
            .compareTo(dependencyRankOfMap(b.value));
        if (c != 0) return c;
        final t = entryMs(a.value).compareTo(entryMs(b.value));
        return t != 0 ? t : (a.key as String).compareTo(b.key as String);
      });

      await _setForeignKeys(false);
      try {
        const microBatchSize = 40;
        for (var i = 0; i < entries.length; i += microBatchSize) {
          final end = (i + microBatchSize < entries.length)
              ? i + microBatchSize
              : entries.length;
          final chunk = entries.sublist(i, end);
          int chunkMaxTs = maxTsMs;
          await db.transaction((txn) async {
            for (final entry in chunk) {
              final v = entry.value;
              if (v is! Map) continue;
              final op = SyncOperation.fromMap(Map<String, Object?>.from(v));
              if (op.workspaceId != workspaceId &&
                  op.workspaceId != 'default' &&
                  workspaceId != 'default' &&
                  op.workspaceId.isNotEmpty) {
                droppedOtherWs++;
                if (droppedSample.isEmpty) droppedSample = op.workspaceId;
                continue;
              }
              final opMs = entryMs(v);
              if (opMs > chunkMaxTs) chunkMaxTs = opMs;
              // idempotent: نفس opId موجود مسبقًا -> تجاهل.
              final idempotentQ = await txn.query(
                'operations',
                where: 'id = ?',
                whereArgs: [op.id],
                limit: 1,
              );
              if (idempotentQ.isNotEmpty) {
                continue;
              }
              String prevOwnerBeforeOp = '';
              if (op.entityType == EntityKind.setting &&
                  op.entityId == 'ownershipTransfer') {
                final curOwnQ = await txn.query(
                  'devices',
                  columns: ['id'],
                  where: 'is_owner = 1',
                  limit: 1,
                );
                if (curOwnQ.isNotEmpty) {
                  prevOwnerBeforeOp = '${curOwnQ.first['id'] ?? ''}';
                }
              }
              final ok = await repo.applyRemoteOperation(txn, op, r);
              if (ok) applied++;
              if (ok &&
                  op.entityType == EntityKind.message &&
                  op.deviceId != ourId) {
                chatOps.add(op);
              }
              if (ok &&
                  op.entityType == EntityKind.user &&
                  op.deviceId != ourId) {
                roleOps.add(op);
              }
              if (ok &&
                  op.entityType == EntityKind.setting &&
                  op.entityId == 'ownershipTransfer' &&
                  op.deviceId != ourId) {
                final curOwnAfterQ = await txn.query(
                  'devices',
                  columns: ['id'],
                  where: 'is_owner = 1',
                  limit: 1,
                );
                final ownerAfterOp = curOwnAfterQ.isNotEmpty
                    ? '${curOwnAfterQ.first['id'] ?? ''}'
                    : '';
                if (ownerAfterOp.isNotEmpty &&
                    ownerAfterOp != prevOwnerBeforeOp) {
                  ownershipOps.add(op);
                }
              }
            }
            // تحديث مؤشر `last_synced_cursor` فوراً داخل نفس معاملة الحفظ لمنع تكرار التنزيل نهائياً
            if (chunkMaxTs > maxTsMs) {
              maxTsMs = chunkMaxTs;
              await saveLastSyncedCursor(maxTsMs, executor: txn);
            }
          });
          if (end < entries.length) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      } finally {
        await _setForeignKeys(true);
      }

      for (final op in chatOps) {
        try {
          final senderRows = await db.query('devices',
              where: 'id = ?', whereArgs: [op.deviceId], limit: 1);
          var senderName = senderRows.isNotEmpty
              ? ((senderRows.first['name'] as String?) ?? '')
              : '';
          if (senderName.trim().isEmpty) senderName = kDefaultMemberName;
          var body = '${op.payload['body'] ?? ''}';
          if (body.isEmpty) {
            body = switch ('${op.payload['kind'] ?? 'text'}') {
              'image' => '📷 صورة',
              'video' => '🎬 فيديو',
              'audio' => '🎙️ رسالة صوتية',
              'file' => '📎 ملف',
              _ => '',
            };
          }
          if (body.isNotEmpty) {
            ChatHooks.onChatMessage?.call(senderName, body);
          }
        } catch (_) {}
      }
      chatOps.clear();

      for (final op in roleOps) {
        try {
          final own = await db.query('devices',
              columns: ['user_id'],
              where: 'id = ?',
              whereArgs: [ourId],
              limit: 1);
          final myUid = own.isNotEmpty ? own.first['user_id'] : null;
          final isOurUser = myUid != null && op.entityId == '$myUid';
          if (!isOurUser) continue;

          final roleCode = '${op.payload['role'] ?? ''}';
          final opUid = int.tryParse(op.entityId);
          if (opUid != null) {
            await db.update('users', {'is_me': 0});
            await db.update('users', {
              'is_me': 1,
              'role': roleCode,
              'active': 1,
            }, where: 'id = ?', whereArgs: [opUid]);
          }

          final roleLabel = switch (roleCode) {
            'admin' => 'المدير',
            'agent' => 'وكيل المدير',
            'accountant' => 'محاسب',
            'dataentry' => 'مدخل بيانات',
            'viewer' => 'عرض فقط',
            _ => roleCode,
          };
          ChatHooks.onMemberNotice?.call(
            'تحدّثت صلاحياتك',
            roleLabel.isEmpty
                ? 'قام المدير بتحديث صلاحيات حسابك — سرى التغيير فوراً.'
                : 'دورك الآن: $roleLabel — سرى التغيير فوراً على هذا الجهاز.',
          );
        } catch (_) {}
      }
      roleOps.clear();

      for (final op in ownershipOps) {
        try {
          final decoded = jsonDecode('${op.payload['value'] ?? '{}'}');
          if (decoded is! Map) continue;
          final newOwnerDev = '${decoded['owner_device_id'] ?? ''}';
          if (newOwnerDev == ourId) {
            if (decoded['handback'] == true) {
              ChatHooks.onMemberNotice?.call(
                '👑 عادت إليك الإدارة',
                'لقد تم استلام صلاحية المدير وعادت إليك — أنت الآن مالك '
                    'المجموعة بكل الصلاحيات، وظهرت لديك إدارة المجموعة '
                    'والأجهزة فوراً.',
              );
            } else {
              ChatHooks.onMemberNotice?.call(
                '👑 أنت الآن مدير المجموعة',
                'سلّمك المدير السابق الإدارة — أصبحت مالك المجموعة بكل '
                    'الصلاحيات، وظهرت لديك إدارة المجموعة والأجهزة فوراً.',
              );
            }
          } else {
            final rows = await db.query('devices',
                columns: ['name'],
                where: 'id = ?',
                whereArgs: [newOwnerDev],
                limit: 1);
            final name = rows.isNotEmpty
                ? '${rows.first['name'] ?? 'جهاز آخر'}'
                : 'جهاز آخر';
            ChatHooks.onMemberNotice?.call(
              'تغيّر مدير المجموعة',
              'انتقلت إدارة المجموعة إلى «$name».',
            );
          }
        } catch (_) {}
      }
      ownershipOps.clear();

      int pageMaxTs = 0;
      for (final entry in entries) {
        final ms = entryMs(entry.value);
        if (ms > pageMaxTs) pageMaxTs = ms;
      }
      if (pageMaxTs > maxTsMs) {
        maxTsMs = pageMaxTs;
        await saveLastSyncedCursor(maxTsMs);
      }

      if (entries.length >= kPullPageSize && pageMaxTs > currentCursorMs) {
        currentCursorMs = pageMaxTs;
        hasMore = true;
      } else {
        hasMore = false;
      }

      if (droppedOtherWs > 0) {
        try {
          await repo.setSetting('sync.droppedOtherWs', '$droppedOtherWs');
          await repo.setSetting('sync.droppedOtherWsSample', droppedSample);
        } catch (_) {}
      }
    }

    if (maxTsMs > lastCursorMs) {
      await saveLastSyncedCursor(maxTsMs);
    }

    await repo.setSetting('lastCloudSync', DateTime.now().toLocal().toString());
    return applied;
  }

  // ==================== الاستماع الفوري (SSE) ====================

  HttpClient? _sseClient;
  bool _listening = false;
  int _sseRetrySeconds = 2;

  /// يُستدعى عند وصول إشعار بتغيير في السحابة — يشغّل pull فوراً.
  void Function()? onCloudChanged;

  bool get isListening => _listening;

  /// يفتح قناة SSE على مسار العمليات مع حصر الاستعلام بالمؤشر الزمني `last_synced_cursor`
  /// `.orderByChild('server_time').startAfter(last_synced_cursor)`.
  Future<void> startListening() async {
    if (_listening) return;
    _listening = true;
    _sseRetrySeconds = 2;
    try {
      DesktopNet.trustedHost = Uri.parse(backendUrl).host;
    } catch (_) {}
    unawaited(_sseLoop());
  }

  Future<void> stopListening() async {
    _listening = false;
    try {
      _sseClient?.close(force: true);
    } catch (_) {}
    _sseClient = null;
  }

  Future<void> _sseLoop() async {
    while (_listening) {
      try {
        final host = Uri.parse(backendUrl).host;
        final pre = await DesktopNet.preflight(host);
        if (pre != null) throw SocketException('preflight: $pre');
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        _sseClient = client;
        final tok = await _idToken();
        final lastCursor = await getLastSyncedCursor();
        // حصر الاستماع اللحظي (SSE) بالاستئناف بعد المؤشر الزمني حصراً:
        // .orderByChild('server_time').startAfter(last_synced_cursor)
        final params = buildCursorQueryParams(
          lastSyncedCursor: lastCursor,
          indexField: 'server_time',
          forRealtimeStream: true,
        );
        if (tok != null) params['auth'] = tok;
        final uri = Uri.parse(_opsPath).replace(queryParameters: params);
        final req = await client.getUrl(uri);
        req.headers.set('Accept', 'text/event-stream');
        req.headers.set('Cache-Control', 'no-cache');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw StateError('sse-http-${resp.statusCode}');
        }
        _sseRetrySeconds = 2; // الاتصال نجح — صفّر التراجع.
        DesktopNet.clearError(); // الشبكة سليمة — امسح أي خطأ معروض.
        String? eventName;
        var skippedInitial = false;
        await for (final line in resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!_listening) break;
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (eventName == 'put' || eventName == 'patch') {
              // أول حدث put هو اللقطة الأولية عند فتح القناة — نتجاهله
              // (السحب الدوري/الافتتاحي يغطيه) ونتفاعل مع ما بعده فقط.
              if (!skippedInitial && eventName == 'put') {
                skippedInitial = true;
              } else {
                try {
                  onCloudChanged?.call();
                } catch (_) {}
              }
            } else if (eventName == 'auth_revoked') {
              break; // أعد الاتصال بتوكن جديد.
            }
          }
        }
      } catch (e) {
        // انقطاع شبكة/خادم — سنعيد المحاولة بعد المهلة، مع تسجيل
        // الخطأ الدقيق (SocketException/HandshakeException/مهلة...)
        // ليُعرض في واجهة المزامنة بدل الفشل الصامت.
        DesktopNet.recordError(e);
      } finally {
        try {
          _sseClient?.close(force: true);
        } catch (_) {}
        _sseClient = null;
      }
      if (!_listening) break;
      await Future<void>.delayed(Duration(seconds: _sseRetrySeconds));
      // تراجع سريع بين 2 إلى 15 ثانية كحد أقصى لسرعة التعافي وإعادة الاتصال.
      _sseRetrySeconds = (_sseRetrySeconds * 2).clamp(2, 15);
    }
  }
}
