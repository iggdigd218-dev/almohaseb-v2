// QA — (3.98.56) تشخيص فشل إنشاء كود الدعوة على جهاز المالك.
//
// العطل المُبلَّغ: عند محاولة إنشاء كود دعوة للأعضاء على **جهاز مدير
// المنشأة** تظهر نافذة «حدث خطأ — ليس لديك الصلاحية لتنفيذ هذا الإجراء،
// يرجى مراجعة مدير النظام». المدير مالك المنشأة، فالبحث عن صلاحية مفقودة
// عبث: السبب الحقيقي واحد من ثلاثة لا علاقة لأي منها بصلاحيات المستخدم:
//
//   ١) لا هوية سحابية فعّالة على الجهاز ⇒ الطلب يُرسل بلا `?auth` ⇒ RTDB
//      يرد 401 (قواعد `auth != null`).
//   ٢) هوية منتهية/مُلغاة ⇒ 401 بعد إعادة المحاولة.
//   ٣) قواعد Firebase Realtime Database لم تُنشر على المشروع ⇒ 403.
//
// وكان `AppErrorMapper` يبتلع كل ما سبق في رسالة «راجع مدير النظام».
//
// العقد بعد الإصلاح:
//  1. رفض السحابة (401/403) يُترجم إلى رسالة سحابية تشخيصية، لا إلى
//     «ليس لديك الصلاحية». 401 (هوية) و403 (قواعد) يُفرَّق بينهما.
//  2. نقص صلاحية حقيقي (`permission denied` من طبقة أخرى بلا سياق سحابي)
//     يبقى يُترجم إلى «ليس لديك الصلاحية» — لم يُكسر السلوك القديم الصحيح.
//  3. `createInvite` يتحقق من الهوية ومن قراءة مساحة العمل قبل توليد أي
//     رمز، بدل إرسال طلب عارٍ يُترجم إلى رسالة صلاحيات خاطئة. والقراءة
//     المرفوضة (401/403) لا تُنتج رمزاً ولا تُنشئ عقداً.
//  4. الفحص التشخيصي **قراءة فقط**: لا يكتب أي عقدة جديدة في Firebase، فلا
//     يحتاج أي تغيير في القواعد المنشورة. (الكتابة إلى عقدة `_probe` كانت
//     تجعل الفحص نفسه سبباً لرفض 403 حين تكون القواعد قديمة/غير منشورة.)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/app_error_mapper.dart';
import 'package:nexora_app/core/auth_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/firebase_auth_service.dart';
import 'package:nexora_app/ui/widgets.dart' show friendlyErrorText;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية ترفض الكتابة بكود محدد (401/403) لمحاكاة قواعد RTDB.
class _RejectingCloud {
  _RejectingCloud(this.statusCode,
      {this.errorBody = '{"error":"Permission denied"}'});
  final int statusCode;
  final String errorBody;
  /// كل مسار كتابة حاول التطبيق تنفيذه (يجب أن يبقى فارغاً للدعوة).
  final List<String> puts = [];

  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status,
          headers: {'content-type': 'application/json; charset=utf-8'});

  http.Client client() => MockClient((req) async {
        if (req.method == 'POST') {
          // Identity Toolkit / securetoken: هوية صالحة حتى نصل للكتابة.
          if (req.url.host.contains('securetoken')) {
            return _json('{"id_token":"TOK-QA","refresh_token":"REF-QA",'
                '"expires_in":"3600","user_id":"UID-QA"}', 200);
          }
          return _json('{"idToken":"TOK-QA","refreshToken":"REF-QA",'
              '"expiresIn":"3600","localId":"UID-QA"}', 200);
        }
        // كل محاولة كتابة تُسجَّل — حتى نتأكد أن رفض القراءة يمنع أي كتابة.
        if (req.method == 'PUT' || req.method == 'PATCH' ||
            req.method == 'DELETE') {
          puts.add(req.url.path);
          return _json(errorBody, statusCode);
        }
        // GET: القواعد/الهوية ترفض القراءة أيضاً (403/401) — هذه هي الحالة
        // الواقعية حين تكون القواعد غير منشورة أو التوكن غير فعّال.
        return _json(errorBody, statusCode);
      });
}

/// سحابة ترفض التوكن القديم بـ 401 وتقبل التوكن المجدّد بـ 200 — للتحقق من
/// تعافي `_probeWorkspaceAccess` و`createInvite` تلقائياً دون ظهور أي خطأ.
class _RecoveringCloud {
  final List<String> seenTokens = [];
  final List<String> puts = [];

  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status,
          headers: {'content-type': 'application/json; charset=utf-8'});

  http.Client client() => MockClient((req) async {
        if (req.method == 'POST') {
          if (req.url.host.contains('securetoken')) {
            return _json('{"id_token":"TOK-FRESH","refresh_token":"REF-NEW",'
                '"expires_in":"3600","user_id":"UID-FRESH"}', 200);
          }
          return _json('{"idToken":"TOK-FRESH","refreshToken":"REF-NEW",'
              '"expiresIn":"3600","localId":"UID-FRESH"}', 200);
        }
        final tok = req.url.queryParameters['auth'] ?? '';
        seenTokens.add(tok);
        if (tok != 'TOK-FRESH') {
          return _json('{"error":"Auth token is expired"}', 401);
        }
        if (req.method == 'PUT' || req.method == 'PATCH') {
          puts.add(req.url.path);
          return _json('{}', 200);
        }
        if (req.url.path.endsWith('/meta.json')) {
          return _json('{"storeName":"منشأة التحقق"}', 200);
        }
        return _json('null', 200);
      });
}

String _makeJwt({required int expSeconds}) {
  final header = base64Url.encode(utf8.encode('{"alg":"RS256","typ":"JWT"}'))
      .replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode('{"sub":"UID-JWT","exp":$expSeconds}'))
      .replaceAll('=', '');
  return '$header.$payload.sig';
}

const _url = 'https://qa-invite-perm.firebaseio.com';
const _ws = 'WS-QA-INVITE-PERM';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // ── ١) ترجمة الأخطاء: السحابة ليست «صلاحية مستخدم» ─────────────────────
  group('INV-PERM-01 ترجمة رفض السحابة في AppErrorMapper', () {
    test('403 من RTDB يُشرح كقواعد غير منشورة لا كصلاحية مفقودة', () {
      final msg = AppErrorMapper.toUserFriendlyMessage(
          StateError('cloud-auth-failed: 403'));
      expect(msg, isNot(contains('ليس لديك الصلاحية')),
          reason: 'المالك ليس ناقص الصلاحية — القواعد هي المشكلة');
      expect(msg, contains('403'));
      expect(msg, contains('قواعد'));
    });

    test('401 من RTDB يُشرح كهوية منتهية تحتاج تسجيل دخول', () {
      final msg = AppErrorMapper.toUserFriendlyMessage(
          StateError('cloud-auth-failed: 401'));
      expect(msg, isNot(contains('ليس لديك الصلاحية')));
      expect(msg, contains('401'));
      expect(msg, contains('Google'));
    });

    test('رسائل CloudJoin العربية للرفض لا تُترجم إلى صلاحية', () {
      final msg = AppErrorMapper.toUserFriendlyMessage(
          'فشل الرفع إلى السحابة: المصادقة مرفوضة (HTTP 403).');
      expect(msg, isNot(contains('ليس لديك الصلاحية')));
      expect(msg, contains('403'));
    });

    test('رسائل _cloudRejectedMessage الفعليّة تحافظ على تفاصيلها عبر friendlyErrorText', () {
      const msg403 = 'رفضت السحابة الكتابة عند "بيانات المنشأة" (HTTP 403). '
          'هذا ليس نقصاً في صلاحيتك كمالك — الأرجح أن قواعد Firebase Realtime Database لم تُنشر على المشروع.';
      const msg401 = 'انتهت صلاحية هوية هذا الجهاز على السحابة عند "invites" (HTTP 401). '
          'سجّل الدخول بحساب Google من الإعدادات ← حساب المؤسسة ثم أعد المحاولة.';
      const msgNoAuth = 'تعذّر إنشاء دعوة الانضمام: لا توجد هوية سحابية فعّالة على هذا الجهاز.';

      for (final raw in const [msg403, msg401, msgNoAuth]) {
        final viaUi = friendlyErrorText(raw);
        final viaMapper = AppErrorMapper.toUserFriendlyMessage(raw);
        for (final out in [viaUi, viaMapper]) {
          expect(out, isNot(contains('ليس لديك الصلاحية')),
              reason: 'ممنوع استبدال رسالة السحابة الصريحة برسالة الصلاحية: $raw');
          expect(out, isNot(contains('مراجعة مدير النظام')));
          expect(out, isNot(contains('رمز الاقتران')));
        }
      }
      expect(friendlyErrorText(msg403), contains('بيانات المنشأة'));
      expect(friendlyErrorText(msg403), contains('403'));
      expect(friendlyErrorText(msg401), contains('invites'));
      expect(friendlyErrorText(msg401), contains('401'));
      expect(friendlyErrorText('INVALID_ID_TOKEN'), isNot(contains('رمز الاقتران')));
    });

    test('نقص صلاحية حقيقي من طبقة داخلية يبقى كما هو', () {
      expect(
        AppErrorMapper.toUserFriendlyMessage('permission denied for table tx'),
        AppErrorMapper.permissionDeniedMessage,
      );
    });

    test('رسالة السحابة العامة موجودة ومفيدة', () {
      expect(AppErrorMapper.cloudAuthRejectedMessage, contains('Google'));
      expect(AppErrorMapper.cloudAuthRejectedMessage,
          isNot(contains('ليس لديك الصلاحية')));
    });
  });

  // ── ٢) createInvite يفشل مبكراً برسالة صحيحة ويتعافى من التوكن المنتهي ──
  group('INV-PERM-02 إنشاء الدعوة على جهاز المالك', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexora_invite_perm_');
      db = await databaseFactory.openDatabase('${tmp.path}/i.db',
          options: OpenDatabaseOptions(
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
      await AppDatabase.createSchema(db);
      repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
      await repo.setSetting('cloudBackendUrl', _url);
      await db.delete('workspaces');
      await db.insert('workspaces', {
        'id': _ws,
        'name': 'منشأة التحقق',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await repo.setSetting('sync.workspaceId', _ws);
      await repo.refreshWorkspaceId();
    });

    tearDown(() async {
      debugFirebaseApiKeyOverride = null;
      FirebaseAuthRest.clearMockForTest();
      await db.close();
      await tmp.delete(recursive: true);
    });

    test('403 من السحابة يعطي رسالة قواعد واضحة بلا ذكر «صلاحية»', () async {
      FirebaseAuthRest.setMockTokenForTest();
      final cloud = _RejectingCloud(403);
      await expectLater(
        http.runWithClient(() => CloudJoin.createInvite(repo), cloud.client),
        throwsA(isA<CloudJoinException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('403'),
            contains('قواعد'),
            isNot(contains('ليس لديك الصلاحية')),
            isNot(contains('مراجعة مدير النظام')),
          ),
        )),
      );
      // الفحص التشخيصي قراءة فقط: لم تُحاول أي كتابة إطلاقاً — لا عقدة فحص
      // جديدة ولا دعوة ولا فهرس. هذا ما يجعل الإصلاح لا يحتاج تغيير القواعد.
      expect(cloud.puts, isEmpty,
          reason: 'لا كتابة قبل التأكد من صلاحية القراءة/الهوية: ${cloud.puts}');
    });

    test('401 من السحابة يعطي رسالة هوية منتهية لا صلاحية', () async {
      FirebaseAuthRest.setMockTokenForTest();
      final cloud = _RejectingCloud(401);
      await expectLater(
        http.runWithClient(() => CloudJoin.createInvite(repo), cloud.client),
        throwsA(isA<CloudJoinException>().having(
          (e) => e.message,
          'message',
          allOf(contains('401'), isNot(contains('ليس لديك'))),
        )),
      );
    });

    test('401 مع "Permission denied" يُفسّر كرفض قواعد RTDB لا انتهاء تسجيل الدخول', () async {
      FirebaseAuthRest.setMockTokenForTest();
      final cloud =
          _RejectingCloud(401, errorBody: '{"error":"Permission denied"}');
      await expectLater(
        http.runWithClient(() => CloudJoin.createInvite(repo), cloud.client),
        throwsA(isA<CloudJoinException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('401'),
            contains('رفضت السحابة'),
            contains('قواعد Firebase Realtime Database'),
            isNot(contains('انتهت صلاحية')),
            isNot(contains('ليس لديك الصلاحية')),
          ),
        )),
      );
    });

    test('401 مع "Auth token is expired" يطلب إعادة تسجيل الدخول بحساب Google', () async {
      FirebaseAuthRest.setMockTokenForTest();
      final cloud =
          _RejectingCloud(401, errorBody: '{"error":"Auth token is expired"}');
      await expectLater(
        http.runWithClient(() => CloudJoin.createInvite(repo), cloud.client),
        throwsA(isA<CloudJoinException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('401'),
            contains('انتهت صلاحية'),
            contains('Google'),
            isNot(contains('ليس لديك الصلاحية')),
          ),
        )),
      );
    });

    test('حجب الجذر /invite_index بـ 401 لا يمنع إنشاء الدعوة واكتشافها وتقديم طلب الانضمام', () async {
      FirebaseAuthRest.setMockTokenForTest();
      final store = <String, Map<String, dynamic>>{
        '/workspaces/$_ws/meta.json': {'storeName': 'منشأة التحقق'},
      };
      http.Client liveSimClient() => MockClient((req) async {
            final p = req.url.path;
            if (req.method == 'POST') {
              if (req.url.host.contains('securetoken')) {
                return _RejectingCloud._json(
                    '{"id_token":"TOK-LIVE","refresh_token":"REF-LIVE","expires_in":"3600","user_id":"UID-LIVE"}',
                    200);
              }
              return _RejectingCloud._json(
                  '{"idToken":"TOK-LIVE","refreshToken":"REF-LIVE","expiresIn":"3600","localId":"UID-LIVE"}',
                  200);
            }
            if (p.startsWith('/invite_index')) {
              return _RejectingCloud._json('{"error":"Permission denied"}', 401);
            }
            if (p == '/workspaces.json') {
              throw StateError('Must not scan /workspaces.json');
            }
            if (req.method == 'PUT') {
              final decoded = jsonDecode(req.body);
              if (decoded is Map) {
                store[p] = Map<String, dynamic>.from(decoded);
              }
              return _RejectingCloud._json(req.body, 200);
            }
            if (req.method == 'PATCH') {
              final existing = store[p] ?? <String, dynamic>{};
              final decoded = jsonDecode(req.body) as Map;
              store[p] = {...existing, ...Map<String, dynamic>.from(decoded)};
              return _RejectingCloud._json('{}', 200);
            }
            if (req.method == 'DELETE') {
              store.remove(p);
              return _RejectingCloud._json('null', 200);
            }
            final v = store[p];
            return _RejectingCloud._json(v == null ? 'null' : jsonEncode(v), 200);
          });

      final invite = await http.runWithClient(
        () => CloudJoin.createInvite(repo),
        liveSimClient,
      );
      expect(invite.token, isNotEmpty);
      expect(invite.pin.length, 6);
      expect(
        store['/workspaces/_invite_index/invites/pin_${invite.pin}.json']?['ws'],
        _ws,
      );
      expect(
        store['/workspaces/_invite_index/invites/tok_${invite.token}.json']?['ws'],
        _ws,
      );
      expect(store['/workspaces/$_ws/invites/${invite.token}.json'], isNotNull);

      final byPin = await http.runWithClient(
        () => CloudJoin.findWorkspaceByInvite(
            backendUrl: _url, tokenOrPin: invite.pin),
        liveSimClient,
      );
      expect(byPin, _ws);

      final byTok = await http.runWithClient(
        () => CloudJoin.findWorkspaceByInvite(
            backendUrl: _url, tokenOrPin: invite.token),
        liveSimClient,
      );
      expect(byTok, _ws);

      final memberDb = await databaseFactory.openDatabase(
          '${tmp.path}/member.db',
          options: OpenDatabaseOptions(
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
      try {
        await AppDatabase.createSchema(memberDb);
        final memberRepo = Repo(databaseProvider: () async => memberDb);
        await memberRepo.initSyncInfra();
        await http.runWithClient(
          () => CloudJoin.requestJoin(
            memberRepo,
            backendUrl: _url,
            tokenOrPin: invite.pin,
            deviceName: 'جهاز عضو للاختبار',
          ),
          liveSimClient,
        );
        expect(
          store.keys.any((k) => k.startsWith('/workspaces/$_ws/joinRequests/')),
          isTrue,
        );
      } finally {
        await memberDb.close();
      }
    });

    test('401 بسبب توكن مخزّن قديم يتجدد تلقائياً في _probeWorkspaceAccess وتنجح الدعوة', () async {
      debugFirebaseApiKeyOverride = 'AIzaSyTestKeyForInviteRecovery123456';
      FirebaseAuthRest.setMockTokenForTest(token: 'TOK-OLD', uid: 'UID-OLD');
      final cloud = _RecoveringCloud();
      final invite = await http.runWithClient(
        () => CloudJoin.createInvite(repo),
        cloud.client,
      );
      expect(invite.token, isNotEmpty);
      expect(invite.pin.length, 6);
      expect(cloud.seenTokens.first, 'TOK-OLD');
      expect(cloud.seenTokens, contains('TOK-FRESH'));
      expect(cloud.puts, isNotEmpty);
    });

    test('كشف انتهاء JWT محلياً من حقل exp دون التأثير على التوكنات الصالحة', () {
      final expiredJwt = _makeJwt(expSeconds: 1000000);
      FirebaseAuthRest.setMockTokenForTest(token: expiredJwt, uid: 'UID-EXP');
      expect(FirebaseAuthRest.hasValidToken, isFalse);
      expect(FirebaseAuthRest.cachedIdToken, isNull);

      final futureExp =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
      final validJwt = _makeJwt(expSeconds: futureExp);
      FirebaseAuthRest.setMockTokenForTest(token: validJwt, uid: 'UID-OK');
      expect(FirebaseAuthRest.hasValidToken, isTrue);
      expect(FirebaseAuthRest.cachedIdToken, validJwt);
    });

    test('تطبيع رمز الاقتران يقبل الأرقام العربية والمسافات والشرطات وفروق التوقيت والمسح الاحتياطي', () async {
      expect(CloudJoin.normalizeInviteCode(' ٦٠٦ ١٠٨ '), '606108');
      expect(CloudJoin.normalizeInviteCode('606-108'), '606108');
      expect(CloudJoin.normalizeInviteCode('۶۰۶_۱۰۸'), '606108');
      expect(CloudJoin.normalizeInviteCode('  9pjl-2kb6 '), '9PJL2KB6');

      FirebaseAuthRest.setMockTokenForTest();
      final localTz = DateTime.now().timeZoneOffset.inMinutes;
      // محاكاة مدير في منطقة زمنية متأخرة بـ 3 ساعات (بلا tzOffsetMin أو معه)
      final managerNow = DateTime.now().subtract(const Duration(hours: 3));
      final managerExp = managerNow.add(const Duration(minutes: 15));
      final store = <String, dynamic>{
        '/workspaces.json': {'WS-LEGACY99': true, '_invite_index': true},
        '/workspaces/WS-LEGACY99/invites.json': {
          'TOKLEG99': {
            'pin': '606108',
            'ws': 'WS-LEGACY99',
            'createdAt': managerNow.toIso8601String(),
            'expiresAt': managerExp.toIso8601String(),
            'tzOffsetMin': localTz - 180,
          },
        },
        '/workspaces/WS-LEGACY99/invites/TOKLEG99.json': {
          'pin': '606108',
          'ws': 'WS-LEGACY99',
          'createdAt': managerNow.toIso8601String(),
          'expiresAt': managerExp.toIso8601String(),
          'tzOffsetMin': localTz - 180,
        },
      };

      http.Client fallbackClient() => MockClient((req) async {
            final p = req.url.path;
            if (req.method == 'POST') {
              return _RejectingCloud._json(
                  '{"idToken":"TOK-LIVE","refreshToken":"REF-LIVE","expiresIn":"3600","localId":"UID-LIVE"}',
                  200);
            }
            if (req.method == 'PUT') {
              store[p] = jsonDecode(req.body);
              return _RejectingCloud._json(req.body, 200);
            }
            final v = store[p];
            return _RejectingCloud._json(
                v == null ? 'null' : jsonEncode(v), 200);
          });

      // على الرغم من غياب السجل من _invite_index واختلاف التوقيت بـ 3 ساعات وإدخال أرقام عربية بمسافة:
      final resolved = await http.runWithClient(
        () => CloudJoin.verifyAndResolveInvite(
          backendUrl: _url,
          tokenOrPin: '٦٠٦ ١٠٨',
        ),
        fallbackClient,
      );
      expect(resolved.workspaceId, 'WS-LEGACY99');
      expect(resolved.token, 'TOKLEG99');
    });

    test('عدم ابتلاع أخطاء رفض القواعد (403/401) أثناء التحقق من رمز الاقتران', () async {
      FirebaseAuthRest.setMockTokenForTest();
      final cloud =
          _RejectingCloud(403, errorBody: '{"error":"Permission denied"}');
      await expectLater(
        http.runWithClient(
          () => CloudJoin.verifyAndResolveInvite(
            backendUrl: _url,
            tokenOrPin: '606108',
          ),
          cloud.client,
        ),
        throwsA(isA<CloudJoinException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('رفضت السحابة'),
            contains('403'),
            isNot(contains('رمز الاقتران غير صحيح')),
          ),
        )),
      );
    });
  });

  // ── ٣) لا يتطلب الإصلاح أي تغيير في قواعد Firebase ────────────────────
  //
  // هذا هو العقد الأهم بالنسبة لبيئة المستخدم: قاعدته المنشورة قد تكون
  // قديمة أو ناقصة. لذلك يجب ألا يضيف التطبيق أي عقدة جديدة إلى القواعد،
  // وألا يعتمد التشخيص على `_probe` أو أي مفتاح غير موجود في النسخة المنشورة.
  group('INV-PERM-03 الفحص التشخيصي لا يفرض أي تعديل على قواعد Firebase', () {
    for (final path in const [
      'firebase/database.rules.json',
      'firebase/rules.license-hardened.json',
    ]) {
      test('INV-PERM-03 $path خالٍ من أي عقدة تشخيصية مضافة', () {
        final rules = jsonDecode(File(path).readAsStringSync()) as Map;
        final ws = rules['rules']['workspaces'][r'$ws'] as Map;
        expect(ws.containsKey('_probe'), isFalse,
            reason: 'الفحص قراءة فقط: إضافة عقدة كانت ستُرفض 403 على قواعد '
                'قديمة فتصير هي سبب العطل');
      });
    }

    test('INV-PERM-03 رمز المصدر لا يكتب أي عقدة تشخيصية', () {
      final src = File('lib/data/sync/cloud_join.dart').readAsStringSync();
      expect(src, isNot(contains('/_probe/')),
          reason: 'لا كتابة تشخيصية على السحابة — قراءة meta.json تكفي');
      // القواعد المنشورة تسمح بقراءة meta للجميع (auth != null).
      expect(src, contains('_probeWorkspaceAccess'));
    });
  });
}
