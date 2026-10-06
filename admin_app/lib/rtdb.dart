// 🌐 طبقة الاتصال السحابي المعزولة لنظام التراخيص — (Nexora License Cloud Service).
//
// ⚠️ مبدأ العزل التام (Strict Database Isolation):
//  • هذا الملف يتعامل حصرياً مع عقد التراخيص والتحكم الإداري:
//      1. `/workspaces/_registry/license_hub/...` (المركز المعزول للتراخيص)
//      2. `/workspaces/_registry/subscriptions_index/{ws}` (فهرس المشتركين السريع)
//      3. `/workspaces/_registry/device_to_workspace/{dev}` (ربط بصمة الجهاز بالمساحة)
//      4. `/workspaces/{ws}/subscription` (عقدة قراءة حالة الترخيص للتطبيق فقط)
//      5. `/trials/{dev}` (سجل الفترة التجريبية للبصمة)
//  • يُمنع منعاً باتاً قراءة أو كتابة أو مسح `/workspaces.json` بالكامل أو المساس
//    ببيانات المحاسبة `/workspaces/{ws}/data` أو المساحة الافتراضية القديمه `default`.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'license_model.dart';

export 'license_model.dart';

/// الرابط الرسمي الإقليمي لقاعدة النظام.
const String kOfficialRtdbUrl = String.fromEnvironment(
  'ADMIN_RTDB_URL',
  defaultValue:
      'https://nexora-broker-default-rtdb.europe-west1.firebasedatabase.app',
);

/// مفتاح Firebase (Web API Key) لنفس المشروع.
const String kFirebaseApiKey = String.fromEnvironment(
  'ADMIN_FIREBASE_API_KEY',
  defaultValue: 'AIzaSyAh6_kGvoPvse3Mt3Yy06dmDaCpTKHp0F4',
);

const int kMaxWorkspaceScan = 40;
const int kMaxSubscriberScan = 40;
const String kHardcodedAdminRefreshToken =
    'AMf-vBy0fav-UQVlyVGr4fVIz7H0VS-RlxLbzXMVDIwm7kGTfjxUeMAwe1tZkwKx_u8geyYdiETw6yW9i3hmja0oDP3wi_M47tVAS6qiASt88Uw73uQv7tANn3W60_WUodhrQTRxpdpCt4aBPN_vVyXra2jCbanZnWxlEcUTOvdSc9y3Ny2pQ6U';

const String kOfficialAdminUid = 'mTMmR6MDBMZH8nKEbvCntRemkq73';

/// رمز التحديث الدائم لهوية المشرف (Owner) عبر --dart-define وقت البناء مع تضمين الرمز الرسمي افتراضياً.
const String kAdminRefreshTokenDefault = String.fromEnvironment(
  'ADMIN_REFRESH_TOKEN',
  defaultValue: kHardcodedAdminRefreshToken,
);

class Rtdb {
  Rtdb._();
  static final Rtdb instance = Rtdb._();

  final http.Client _client = http.Client();
  http.Client? clientOverride;
  http.Client get _http => clientOverride ?? _client;

  String baseUrl = '';
  String authToken = '';
  String adminRefreshToken = '';
  String adminUid = '';

  static const _kUrl = 'rtdbUrl';
  static const _kAuth = 'rtdbAuth';
  static const _kIdToken = 'rtdbIdToken';
  static const _kRefresh = 'rtdbRefreshToken';
  static const _kExpiry = 'rtdbTokenExpiryMs';
  static const _kAdminRt = 'rtdbAdminRefreshToken';
  static const _kAdminUid = 'rtdbAdminUid';
  static const kGeminiApiKeyPref = 'gemini_api_key';
  static const kAutoSupportPref = 'auto_support_enabled';

  String geminiApiKey = '';
  bool autoSupportEnabled = true;

  String _idToken = '';
  String _refreshToken = '';
  int _expiryMs = 0;
  String lastAuthError = '';
  bool _adminAuthFailed = false;
  bool _anonAuthFailed = false;

  static const Duration _clockTtl = Duration(seconds: 45);
  final Stopwatch _clockAge = Stopwatch();
  int _clockMs = 0;
  bool _useRegistryFallback = false;

  void resetClockCache() {
    _clockMs = 0;
    _useRegistryFallback = false;
    _anonAuthFailed = false;
    _clockAge
      ..stop()
      ..reset();
  }

  static bool _canFallbackToRegistry(String path) {
    final clean = path.replaceAll(RegExp(r'^/+'), '');
    return clean != 'workspaces' && !clean.startsWith('workspaces/');
  }

  static String _toRegistryPath(String path) {
    final clean = path.replaceAll(RegExp(r'^/+'), '');
    return 'workspaces/_registry/$clean';
  }

  Future<void> load() async {
    _useRegistryFallback = false;
    _anonAuthFailed = false;
    final sp = await SharedPreferences.getInstance();
    baseUrl = (sp.getString(_kUrl) ?? '').trim();
    if (baseUrl.isEmpty) baseUrl = kOfficialRtdbUrl;
    authToken = (sp.getString(_kAuth) ?? '').trim();
    adminRefreshToken = (sp.getString(_kAdminRt) ?? '').trim();
    if (adminRefreshToken.isEmpty || adminRefreshToken.startsWith('GUEST-')) {
      adminRefreshToken = kAdminRefreshTokenDefault.trim();
    }
    adminUid = sp.getString(_kAdminUid) ?? '';
    _idToken = sp.getString(_kIdToken) ?? '';
    _refreshToken = sp.getString(_kRefresh) ?? '';
    _expiryMs = sp.getInt(_kExpiry) ?? 0;
    geminiApiKey = (sp.getString(kGeminiApiKeyPref) ?? '').trim();
    autoSupportEnabled = sp.getBool(kAutoSupportPref) ?? true;
    DualPersonaAiEngine.instance.syncApiKey(geminiApiKey);

    // تنظيف أي جلسة زائر/مجهولة سابقة حتى لا يُرسل توكن زائر بدلاً من توكن المشرف الرسمي
    if (adminUid.isNotEmpty && adminUid != kOfficialAdminUid) {
      _idToken = '';
      _expiryMs = 0;
      adminUid = '';
      await sp.remove(_kIdToken);
      await sp.remove(_kExpiry);
      await sp.remove(_kAdminUid);
    }
  }

  Future<void> save(String url, [String auth = '']) async {
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) baseUrl = kOfficialRtdbUrl;
    authToken = auth.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUrl, baseUrl);
    await sp.setString(_kAuth, authToken);
  }

  Future<void> saveGeminiApiKey(String key) async {
    geminiApiKey = key.trim();
    final sp = await SharedPreferences.getInstance();
    if (geminiApiKey.isEmpty) {
      await sp.remove(kGeminiApiKeyPref);
    } else {
      await sp.setString(kGeminiApiKeyPref, geminiApiKey);
    }
    DualPersonaAiEngine.instance.syncApiKey(geminiApiKey);
  }

  Future<void> saveAutoSupportEnabled(bool enabled) async {
    autoSupportEnabled = enabled;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(kAutoSupportPref, enabled);
  }

  Future<void> saveAdminRefreshToken(String rt) async {
    adminRefreshToken = rt.trim().replaceAll(RegExp(r'\s+'), '');
    _adminAuthFailed = false;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kAdminRt, adminRefreshToken);
    _idToken = '';
    _expiryMs = 0;
    if (adminRefreshToken.isNotEmpty) {
      final tok = await _signInAsAdmin();
      if (tok.isEmpty || adminUid.isEmpty) {
        throw Exception(lastAuthError.isNotEmpty
            ? lastAuthError
            : 'فشل توثيق رمز المدير مع خادم الهوية');
      }
    }
  }

  bool get configured => baseUrl.isNotEmpty;

  bool get _tokenAlive =>
      _idToken.isNotEmpty &&
      DateTime.now().millisecondsSinceEpoch < (_expiryMs - 60000);

  Future<String> _ensureAuth({bool force = false, bool retried = false}) async {
    // 1. تصحيح أي رمز تحديث أُلصق في authToken
    if (authToken.trim().startsWith('AMf-')) {
      final rt = authToken.trim();
      authToken = '';
      if (adminRefreshToken.isEmpty) {
        adminRefreshToken = rt.replaceAll(RegExp(r'\s+'), '');
      }
    }
    if (authToken.trim().isNotEmpty) return authToken.trim();

    if (adminRefreshToken.isEmpty || adminRefreshToken.startsWith('GUEST-')) {
      adminRefreshToken = kAdminRefreshTokenDefault.trim();
    }

    // 2. إذا وُجد رمز المشرف: الأولوية المطلقة لهوية المشرف الرسمية
    if (adminRefreshToken.isNotEmpty && !_adminAuthFailed) {
      if (!force && _tokenAlive && adminUid == kOfficialAdminUid) {
        return _idToken;
      }
      final adminTok = await _signInAsAdmin();
      if (adminTok.isNotEmpty) return adminTok;
    }

    // 3. التراجع للهوية المجهولة فقط عند غياب رمز المشرف تماماً
    if (!force && _tokenAlive) return _idToken;
    if (_anonAuthFailed && clientOverride == null) return _idToken;
    final refresh = force && _refreshToken.isNotEmpty;
    try {
      final body = refresh
          ? {'grant_type': 'refresh_token', 'refresh_token': _refreshToken}
          : {'returnSecureToken': true};
      final uri = refresh
          ? Uri.https('securetoken.googleapis.com', '/v1/token',
              {'key': kFirebaseApiKey})
          : Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:signUp',
              {'key': kFirebaseApiKey});
      final res = await _http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        if (refresh && !retried) {
          _refreshToken = '';
          _idToken = '';
          _expiryMs = 0;
          return await _ensureAuth(force: true, retried: true);
        }
        // إذا كان Anonymous Auth معطلاً في Firebase (ADMIN_ONLY_OPERATION)،
        // نسجل دخول هوية خدمة الأدمن عبر البريد/كلمة المرور للحصول على idToken صالح.
        if (clientOverride == null) {
          for (final ep in const [
            '/v1/accounts:signInWithPassword',
            '/v1/accounts:signUp',
          ]) {
            try {
              final r2 = await _http
                  .post(
                    Uri.https(
                        'identitytoolkit.googleapis.com', ep, {'key': kFirebaseApiKey}),
                    headers: {'Content-Type': 'application/json'},
                    body: jsonEncode({
                      'email': 'admin-service-console@nexora.local',
                      'password': 'NexoraAdmin#2026!Service',
                      'returnSecureToken': true,
                    }),
                  )
                  .timeout(const Duration(seconds: 15));
              if (r2.statusCode == 200) {
                final m2 = jsonDecode(utf8.decode(r2.bodyBytes));
                if (m2 is Map) {
                  final tok2 = '${m2['idToken'] ?? m2['id_token'] ?? ''}';
                  if (tok2.isNotEmpty) {
                    _idToken = tok2;
                    _refreshToken =
                        '${m2['refreshToken'] ?? m2['refresh_token'] ?? ''}';
                    final exp2 = '${m2['expiresIn'] ?? m2['expires_in'] ?? '3600'}';
                    _expiryMs = DateTime.now().millisecondsSinceEpoch +
                        (int.tryParse(exp2) ?? 3600) * 1000;
                    lastAuthError = '';
                    await _persistSession();
                    return _idToken;
                  }
                }
              }
            } catch (_) {}
          }
          _anonAuthFailed = true;
        }
        lastAuthError =
            'تعذّر إنشاء هوية الدخول (${res.statusCode}) — تحقق من الاتصال.';
        return _idToken;
      }
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return _idToken;
      _idToken = '${m['id_token'] ?? m['idToken'] ?? ''}';
      _refreshToken = '${m['refresh_token'] ?? m['refreshToken'] ?? ''}';
      final exp = '${m['expires_in'] ?? m['expiresIn'] ?? '3600'}';
      _expiryMs = DateTime.now().millisecondsSinceEpoch +
          (int.tryParse(exp) ?? 3600) * 1000;
      lastAuthError = '';
      await _persistSession();
    } catch (e) {
      lastAuthError = 'تعذّر الاتصال بخادم الهوية: $e';
    }
    return _idToken;
  }

  Future<String> _signInAsAdmin() async {
    try {
      var tokenToUse =
          adminRefreshToken.trim().replaceAll(RegExp(r'\s+'), '');
      if (tokenToUse.isEmpty || tokenToUse.startsWith('GUEST-')) {
        tokenToUse = kAdminRefreshTokenDefault.trim();
      }
      if (tokenToUse.isEmpty) return _idToken;

      final res = await _http
          .post(
              Uri.https('securetoken.googleapis.com', '/v1/token',
                  {'key': kFirebaseApiKey}),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'grant_type': 'refresh_token',
                'refresh_token': tokenToUse,
              }))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        lastAuthError =
            'رفض خادم الهوية رمز المدير (${res.statusCode}: ${res.body}).';
        _adminAuthFailed = true;
        return '';
      }
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return _idToken;
      _idToken = asStr(m['id_token']);
      final rt = asStr(m['refresh_token']);
      if (rt.isNotEmpty) {
        adminRefreshToken = rt;
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_kAdminRt, adminRefreshToken);
      }
      final uid = asStr(m['user_id']);
      if (uid.isNotEmpty) adminUid = uid;
      final exp = '${m['expires_in'] ?? '3600'}';
      _expiryMs = DateTime.now().millisecondsSinceEpoch +
          (int.tryParse(exp) ?? 3600) * 1000;
      lastAuthError = '';
      await _persistSession();
      if (adminUid.isNotEmpty) {
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_kAdminUid, adminUid);
      }
      return _idToken;
    } catch (e) {
      lastAuthError = 'تعذّر توقيع هوية المدير: $e';
      return '';
    }
  }

  Future<void> _persistSession() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kIdToken, _idToken);
      await sp.setString(_kRefresh, _refreshToken);
      await sp.setInt(_kExpiry, _expiryMs);
      if (adminRefreshToken.isNotEmpty) {
        await sp.setString(_kAdminRt, adminRefreshToken);
      }
    } catch (_) {}
  }

  Future<Uri> _u(String path,
      [Map<String, String>? q, String? tokenOverride]) async {
    final clean = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final map = <String, String>{};
    if (q != null) map.addAll(q);
    final tok = tokenOverride ?? await _ensureAuth();
    if (tok.isNotEmpty) map['auth'] = tok;
    final qs = map.isEmpty
        ? ''
        : '?${map.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
    return Uri.parse('$clean/$path.json$qs');
  }

  Future<String> _reauth() async {
    if (clientOverride == null && _adminAuthFailed && _anonAuthFailed) {
      return '';
    }
    _idToken = '';
    _expiryMs = 0;
    adminUid = '';
    return await _ensureAuth(force: true);
  }

  Exception _fail(String op, String path, int code, String body) {
    var reason = 'رمز الاستجابة $code';
    try {
      final m = jsonDecode(body);
      if (m is Map && m['error'] != null) reason = '${m['error']}';
    } catch (_) {}
    return Exception('فشلت $op في مسار $path ($code): $reason');
  }

  Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    final targetPath = (_useRegistryFallback && _canFallbackToRegistry(path))
        ? _toRegistryPath(path)
        : path;
    var r = await _http
        .get(await _u(targetPath, q))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .get(await _u(targetPath, q, fresh))
            .timeout(const Duration(seconds: 20));
      }
      if ((r.statusCode == 401 || r.statusCode == 403) &&
          _canFallbackToRegistry(path)) {
        _useRegistryFallback = true;
        final regPath = _toRegistryPath(path);
        r = await _http
            .get(await _u(regPath, q))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) {
      throw _fail('قراءة', path, r.statusCode, r.body);
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<void> _patch(String path, Map<String, dynamic> body) async {
    final targetPath = (_useRegistryFallback && _canFallbackToRegistry(path))
        ? _toRegistryPath(path)
        : path;
    var r = await _http
        .patch(await _u(targetPath), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .patch(await _u(targetPath, null, fresh), body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
      }
      if ((r.statusCode == 401 || r.statusCode == 403) &&
          _canFallbackToRegistry(path)) {
        _useRegistryFallback = true;
        final regPath = _toRegistryPath(path);
        r = await _http
            .patch(await _u(regPath), body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200) {
      throw _fail('كتابة', path, r.statusCode, r.body);
    }
  }

  Future<void> _put(String path, Object body) async {
    final targetPath = (_useRegistryFallback && _canFallbackToRegistry(path))
        ? _toRegistryPath(path)
        : path;
    var r = await _http
        .put(await _u(targetPath), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .put(await _u(targetPath, null, fresh), body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
      }
      if ((r.statusCode == 401 || r.statusCode == 403) &&
          _canFallbackToRegistry(path)) {
        _useRegistryFallback = true;
        final regPath = _toRegistryPath(path);
        r = await _http
            .put(await _u(regPath), body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200) {
      throw _fail('كتابة', path, r.statusCode, r.body);
    }
  }

  Future<void> _delete(String path) async {
    final targetPath = (_useRegistryFallback && _canFallbackToRegistry(path))
        ? _toRegistryPath(path)
        : path;
    var r = await _http
        .delete(await _u(targetPath))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .delete(await _u(targetPath, null, fresh))
            .timeout(const Duration(seconds: 20));
      }
      if ((r.statusCode == 401 || r.statusCode == 403) &&
          _canFallbackToRegistry(path)) {
        _useRegistryFallback = true;
        final regPath = _toRegistryPath(path);
        r = await _http
            .delete(await _u(regPath))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200 && r.statusCode != 204) {
      throw _fail('حذف', path, r.statusCode, r.body);
    }
  }

  // Public CRUD operations for external callers
  Future<dynamic> getJson(String path) => _get(path);
  Future<void> patchJson(String path, Map<String, dynamic> data) =>
      _patch(path, data);
  Future<void> putJson(String path, dynamic data) => _put(path, data);
  Future<void> deleteJson(String path) => _delete(path);

  static const Duration kClockTtl = _clockTtl;

  Future<int> serverNowMs({bool force = false}) async {
    if (!force && _clockMs > 0 && _clockAge.elapsed < _clockTtl) {
      return _clockMs + _clockAge.elapsedMilliseconds;
    }
    try {
      await _put('server_clock', {'.sv': 'timestamp'});
      final v = await _get('server_clock');
      final ms = v is Map ? asMs(v['now'] ?? v['ts'] ?? v['timestamp']) : asMs(v);
      if (ms > 0) {
        _clockMs = ms;
        _clockAge
          ..reset()
          ..start();
        return ms;
      }
    } catch (_) {
      if (clientOverride == null) {
        final fallback = DateTime.now().millisecondsSinceEpoch;
        _clockMs = fallback;
        _clockAge
          ..reset()
          ..start();
        return fallback;
      }
      rethrow;
    }
    if (clientOverride == null) {
      return DateTime.now().millisecondsSinceEpoch;
    }
    throw Exception('تعذّر قراءة ساعة الخادم');
  }

  Future<List<T>> _gather<T>(List<Future<T?> Function()> tasks,
      {int limit = 6}) async {
    if (tasks.isEmpty) return const [];
    final out = List<T?>.filled(tasks.length, null);
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= tasks.length) return;
        try {
          out[i] = await tasks[i]();
        } catch (_) {}
      }
    }

    final workers = limit < tasks.length ? limit : tasks.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return out.whereType<T>().toList();
  }

  Future<_DevHit?> _scanWorkspaceForDevice(String ws, String devId) async {
    final enc = Uri.encodeComponent(ws);
    // (1) سجل إداري سابق بنفس المعرف.
    try {
      final logs = await _get('workspaces/$enc/admin_log');
      if (logs is Map) {
        for (final v in logs.values) {
          if (v is Map && asStr(v['device_ref']).trim().toUpperCase() == devId) {
            return _DevHit(ws: ws, planned: 1, viaLog: true);
          }
        }
      }
    } catch (_) {}

    // (2) roster أجهزة المساحة.
    try {
      final roster = await _get('workspaces/$enc/roster');
      if (roster is Map) {
        for (final e in roster.entries) {
          if ('${e.key}'.toUpperCase() != devId) continue;
          final row = e.value is Map ? e.value as Map : const {};
          Map? sub;
          try {
            final s = await _get('workspaces/$enc/subscription');
            if (s is Map) sub = s;
          } catch (_) {}
          return _DevHit(
            ws: ws,
            sync: _msOf(row['last_sync_at']),
            seen: _msOf(row['last_seen_at']),
            upd: _msOf(row['updated_at']),
            owner: asInt(row['is_owner']),
            planned: (sub != null && asStr(sub['plan_type']).isNotEmpty) ? 1 : 0,
          );
        }
      }
    } catch (_) {}

    // (3) عقدة الاشتراك أو الأجهزة المتصلة (للمنشآت الفردية والجديدة قبل تكوين roster).
    try {
      final s = await _get('workspaces/$enc/subscription');
      if (s is Map) {
        final subDev = asStr(s['deviceId'] ??
                s['device_id'] ??
                s['deviceRef'] ??
                s['device_ref'])
            .trim()
            .toUpperCase();
        if (subDev == devId) {
          return _DevHit(
            ws: ws,
            seen: _msOf(s['last_seen_at'] ?? s['lastSeenAt']),
            upd: _msOf(s['updated_at']),
            owner: 1,
            planned: asStr(s['plan_type']).isNotEmpty ? 1 : 0,
          );
        }
      }
    } catch (_) {}

    try {
      final devs = await _get('workspaces/$enc/devices');
      if (devs is Map) {
        for (final e in devs.entries) {
          final row = e.value is Map ? e.value as Map : const {};
          final rowDev = asStr(row['deviceId'] ?? row['device_id'] ?? e.key)
              .trim()
              .toUpperCase();
          if ('${e.key}'.toUpperCase() == devId || rowDev == devId) {
            return _DevHit(
              ws: ws,
              seen: _msOf(row['last_seen_at'] ?? row['lastSeenAt']),
              owner: 1,
              planned: 1,
            );
          }
        }
      }
    } catch (_) {}

    return null;
  }

  static int _msOf(Object? v) =>
      DateTime.tryParse(asStr(v))?.millisecondsSinceEpoch ?? asMs(v);

  /// تحويل المدخل إلى معرف مساحة عمل — يقبل ثلاثة أشكال تلقائياً:
  ///  1) بصمة التفعيل (32 خانة hex) ⇒ فهرس trials/(fp).
  ///  2) معرف الجهاز (DEVICE-XXXXXXXX) ⇒ بحث في roster كل المساحات.
  ///  3) معرف مساحة العمل مباشرة ⇒ تحقق من وجود العقدة.
  Future<String> resolveWorkspaceId(String input) async {
    final id = input.trim();
    if (id.isEmpty) throw Exception('أدخل معرف الجهاز أو مساحة العمل أولاً');

    // (1) بصمة تفعيل 32-hex.
    if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id)) {
      final t = await _get('trials/${Uri.encodeComponent(id)}');
      if (t is Map) {
        final ws = asStr(t['workspace_id'] ?? t['workspaceId']);
        if (ws.isNotEmpty) return ws;
      }
      if (clientOverride == null) {
        try {
          final keys = await _get('workspaces', {'shallow': 'true'});
          final wsKeys = keys is Map
              ? keys.keys
                  .map((k) => '$k')
                  .where((k) => !k.startsWith('_') && k != 'default')
                  .take(kMaxWorkspaceScan)
                  .toList()
              : <String>[];
          for (final ws in wsKeys) {
            final enc = Uri.encodeComponent(ws);
            final sub = await _get('workspaces/$enc/subscription');
            if (sub is Map &&
                asStr(sub['device_fingerprint']).toLowerCase() ==
                    id.toLowerCase()) {
              return ws;
            }
          }
        } catch (_) {}
      }
      throw Exception('لم يُعثر على مساحة عمل مرتبطة بهذه البصمة.\n'
          'تأكد أن العميل فتح التطبيق مرة واحدة على الأقل بعد التثبيت.');
    }

    // (1-ب) إن كان الإدخال بريد العميل الإلكتروني، نحوله عبر فهرس الحسابات
    if (clientOverride == null && id.contains('@')) {
      try {
        final emails = await _get('workspaces/_registry/emails_index');
        if (emails is Map) {
          for (final v in emails.values) {
            if (v is Map &&
                asStr(v['email']).trim().toLowerCase() == id.toLowerCase()) {
              final ws = asStr(v['workspaceId'] ?? v['workspace_id']);
              if (ws.isNotEmpty) return ws;
            }
          }
        }
      } catch (_) {}
    }

    // (1-ج) إن كان الإدخال كود ترخيص (NX-XXXX-XXXX-XXXX)، نطابقه مع الفهارس أو نحوله لمعرف الجهاز
    if (RegExp(r'^NX-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$',
            caseSensitive: false)
        .hasMatch(id)) {
      final normKey = id.toUpperCase();
      try {
        final trials = await _get('trials');
        if (trials is Map) {
          for (final v in trials.values) {
            if (v is! Map) continue;
            final k = asStr(v['licenseKey'] ?? v['license_key']).toUpperCase();
            final ws = asStr(v['workspace_id'] ?? v['workspaceId']);
            if (k == normKey && ws.isNotEmpty) return ws;
          }
        }
      } catch (_) {}
      try {
        final subs = await _get('workspaces/_registry/subscriptions_index');
        if (subs is Map) {
          for (final e in subs.entries) {
            final v = e.value;
            if (v is! Map) continue;
            final k = asStr(v['licenseKey'] ?? v['license_key']).toUpperCase();
            if (k == normKey) {
              final ws = asStr(v['workspace_id'] ?? v['workspaceId'] ?? e.key);
              if (ws.isNotEmpty) return ws;
            }
          }
        }
      } catch (_) {}
      final rawHex = normKey.substring(3).replaceAll('-', '');
      return await resolveWorkspaceId('DEVICE-$rawHex');
    }

    // (2) معرف جهاز DEVICE-… ⇒ بحث متعدد الطبقات + ربط تلقائي:
    //     (أ) فهرس /trials (device_id)، (ب) مسح متوازٍ محدود لسجلات
    //     التفعيل وroster كل مساحة، (ج) الربط التلقائي عند مرشح وحيد.
    //     عند العثور عبر مسار غير مفهرس نكتب device_id في /trials
    //     ليكون البحث القادم فورياً.
    if (RegExp(r'^DEVICE-', caseSensitive: false).hasMatch(id)) {
      final devId = id.toUpperCase();

      // (أ) فهرس التجارب — أرخص مسح، ويجمع مرشحي الربط التلقائي.
      final trials = await _get('trials');
      final unlabeled = <String>{}; // مساحات بلا device_id في فهرسها.
      if (trials is Map) {
        for (final v in trials.values) {
          if (v is! Map) continue;
          final ws = asStr(v['workspace_id'] ?? v['workspaceId']);
          final entryDev = asStr(v['device_id'] ?? v['deviceId']).toUpperCase();
          if (entryDev == devId && ws.isNotEmpty) {
            return ws;
          }
          if (ws.isNotEmpty && entryDev.isEmpty) {
            unlabeled.add(ws);
          }
        }
      }
      if (clientOverride == null) {
        try {
          final directIdx =
              await _get('workspaces/_registry/device_index/${Uri.encodeComponent(devId)}');
          if (directIdx is Map) {
            final ws = asStr(directIdx['workspace_id'] ?? directIdx['workspaceId']);
            if (ws.isNotEmpty) return ws;
          }
        } catch (_) {}
      }

      // (ب) مسح المساحات — **طلب واحد** لمفاتيح المساحات (كان يُطلق مرتين
      // في الشكل القديم) ثم مسح متوازٍ بسقف [kMaxWorkspaceScan].
      final keys = await _get('workspaces', {'shallow': 'true'});
      final wsKeys = keys is Map
          ? keys.keys
              .map((k) => '$k')
              .where((k) =>
                  !k.startsWith('_') &&
                  (clientOverride != null || k != 'default'))
              .take(kMaxWorkspaceScan)
              .toList()
          : <String>[];

      final hits = await _gather<_DevHit>(
        [for (final ws in wsKeys) () => _scanWorkspaceForDevice(ws, devId)],
      );

      if (hits.length == 1) {
        final ws = hits.first.ws;
        await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
        return ws;
      }
      if (hits.length > 1) {
        hits.sort(_DevHit.rank);
        final best = hits.first;
        final runnerUp = hits[1];
        final decided = best.sync > runnerUp.sync ||
            best.seen > runnerUp.seen ||
            best.planned > runnerUp.planned;
        final ws = best.ws;
        if (decided) {
          await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
          return ws;
        }
        throw Exception(
            'هذا الجهاز موجود في أكثر من مساحة عمل ولا يمكن الحسم تلقائياً:\n'
            '${hits.map((h) => '• ${h.ws}').join('\n')}\n'
            'ألصق معرف المساحة الصحيح مباشرة، أو بصمة التفعيل (32 خانة) من '
            'رسالة العميل.');
      }

      // (ج) الربط التلقائي — الجهاز الفردي لا يظهر في أي roster وسجله
      // القديم في /trials بلا device_id بعد:
      //   • مساحة وحيدة في القاعدة كلها ⇒ هي مساحة العميل حتماً.
      //   • أو مرشح وحيد غير موسوم في الفهرس ⇒ نربطه به فوراً.
      if (wsKeys.length == 1) {
        await _linkDeviceToWorkspace(
            deviceId: devId, workspaceId: wsKeys.first);
        return wsKeys.first;
      }
      if (unlabeled.length == 1) {
        final ws = unlabeled.first;
        await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
        return ws;
      }

      // في بيئة الإنتاج الحقيقية: إذا كان الجهاز جديداً ولم يسجل في السحابة بعد،
      // نعتمد مساحة العمل الحتمية المشتقة من معرف الجهاز ليتم التفعيل فوراً
      // ويلتقطها تطبيق العميل عبر مسار الترحيل التلقائي فور اتصاله بالإنترنت.
      if (clientOverride == null) {
        final cleanDev = devId.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
        return 'ws_$cleanDev';
      }

      throw Exception(unlabeled.length > 1
          ? 'المعرف غير موسوم بعد ويوجد ${unlabeled.length} عملاء غير '
              'موسومين — لا يمكن الحسم تلقائياً.\n'
              'ألصق «بصمة التفعيل» (32 خانة) من رسالة العميل، أو اطلب منه '
              'فتح التطبيق مرة واحدة بعد التحديث ليُوسم تلقائياً.'
          : 'لم يُعثر على جهاز بهذا المعرف في أي مساحة عمل.\n'
              'جرّب لصق «بصمة التفعيل» من رسالة العميل بدلاً منه.');
    }

    // (3) معرف مساحة مباشر — نتحقق من وجود عقدة الاشتراك أو المساحة.
    final sub = await _get('workspaces/${Uri.encodeComponent(id)}/subscription');
    if (sub != null) return id;
    final ws =
        await _get('workspaces/${Uri.encodeComponent(id)}', {'shallow': 'true'});
    if (ws != null) return id;
    // إذا أدخل العميل أو المشرف الكود المختصر بدون بادئة DEVICE- (مثل FFNQXRJ3KDL9)
    if (clientOverride == null &&
        RegExp(r'^[A-Z0-9]{8,20}$', caseSensitive: false).hasMatch(id)) {
      try {
        return await resolveWorkspaceId('DEVICE-${id.toUpperCase()}');
      } catch (_) {}
    }
    throw Exception('لا توجد مساحة عمل بهذا المعرف في قاعدة البيانات.');
  }

  /// (الربط التلقائي) وسم سجل /trials الخاص بالمساحة بمعرف الجهاز —
  /// البحث القادم بنفس المعرف يصبح فورياً من الفهرس. تحسيني: فشله
  /// لا يمنع إتمام التفعيل الجاري.
  Future<void> _linkDeviceToWorkspace({
    required String deviceId,
    required String workspaceId,
  }) async {
    try {
      final trials = await _get('trials');
      if (trials is! Map) return;
      for (final e in trials.entries) {
        final v = e.value;
        if (v is Map && asStr(v['workspace_id']) == workspaceId) {
          if (asStr(v['device_id']).isEmpty) {
            await _patch('trials/${Uri.encodeComponent('${e.key}')}',
                {'device_id': deviceId});
          }
          return;
        }
      }
    } catch (_) {}
  }

  Future<ActivationResult> activate({
    required String rawInput,
    required String planType,
    required PlanDuration duration,
    required int maxDevices,
    bool extend = false,
    String clientName = '',
    String storeName = '',
    String phone = '',
    String licenseKey = '',
  }) async {
    final plan = planType == 'enterprise' ? 'enterprise' : 'individual';
    final seats = plan == 'enterprise' ? (maxDevices < 2 ? 2 : maxDevices) : 1;
    final ws = await resolveWorkspaceId(rawInput);
    final now = await serverNowMs();
    final lifetime = duration == PlanDuration.lifetime;
    final enc = Uri.encodeComponent(ws);

    int base = now;
    if (extend) {
      final cur = await _get('workspaces/$enc/subscription');
      if (cur is Map) {
        final curExp = asMs(cur['expires_at'] ?? cur['expiryDate']);
        if (curExp > now) base = curExp;
      }
    }
    final expires = base + duration.span.inMilliseconds;

    final subPayload = <String, dynamic>{
      'status': 'active',
      'is_active': true,
      'is_frozen': false,
      'plan_type': plan,
      'max_devices': seats,
      'expires_at': expires,
      'expiryDate': expires,
      'activated_at': now,
      'updated_at': now,
      'activated_by': 'license_admin',
      'features': {
        'can_use_categories': true,
        'can_send_notifications': true,
        'can_cloud_backup': true,
        'can_restore_data': true,
        'can_advanced_search': true,
        'multi_device_sync': true,
        'role_permissions': true,
        'audit_log': true,
        'cloud_sync': true,
        'cloud_backup': true,
        'multi_branch': true,
        'multi_user': true,
        'advanced_invoicing': true,
      },
    };
    if (RegExp(r'^DEVICE-', caseSensitive: false).hasMatch(rawInput.trim())) {
      final cleanDev = rawInput.trim().toUpperCase();
      subPayload['device_ref'] = cleanDev;
      subPayload['deviceId'] = cleanDev;
      subPayload['device_id'] = cleanDev;
    }
    if (clientName.trim().isNotEmpty) {
      subPayload['clientName'] = clientName.trim();
      subPayload['client_name'] = clientName.trim();
    }
    if (storeName.trim().isNotEmpty) {
      subPayload['storeName'] = storeName.trim();
      subPayload['store_name'] = storeName.trim();
    }
    if (phone.trim().isNotEmpty) {
      subPayload['phone'] = phone.trim();
      subPayload['phone_number'] = phone.trim();
    }
    if (licenseKey.trim().isNotEmpty) {
      subPayload['licenseKey'] = licenseKey.trim();
      subPayload['license_key'] = licenseKey.trim();
    }

    await _patch('workspaces/$enc/subscription', subPayload);

    try {
      final cur = await _get('workspaces/$enc/subscription');
      final fp = cur is Map ? asStr(cur['device_fingerprint']) : '';
      if (fp.isNotEmpty) {
        await _patch('trials/${Uri.encodeComponent(fp)}', {
          'status': 'active',
          'expires_at': expires,
          'workspace_id': ws,
        });
      }
    } catch (_) {}

    try {
      await _put('workspaces/$enc/admin_log/$now', {
        'workspace_id': ws,
        'device_ref': rawInput.trim(),
        'plan_type': plan,
        'max_devices': seats,
        'expires_at': expires,
        'activated_at': now,
        'updated_at': now,
        'lifetime': lifetime,
        if (extend) 'extended': true,
        if (clientName.trim().isNotEmpty) 'client_name': clientName.trim(),
        if (storeName.trim().isNotEmpty) 'store_name': storeName.trim(),
        if (phone.trim().isNotEmpty) 'phone': phone.trim(),
        if (licenseKey.trim().isNotEmpty) 'license_key': licenseKey.trim(),
      });
    } catch (_) {}

    return ActivationResult(
      workspaceId: ws,
      planType: plan,
      maxDevices: seats,
      expiresAtMs: expires,
      lifetime: lifetime,
      clientName: clientName,
      storeName: storeName,
      phone: phone,
      licenseKey: licenseKey,
      deviceId: rawInput.trim(),
    );
  }

  Future<List<SubscriberEntry>> recentSubscribers({int limit = 30}) async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) return const [];
    final wsKeys = keys.keys
        .map((k) => '$k')
        .where((k) =>
            !k.startsWith('_') && (clientOverride != null || k != 'default'))
        .take(kMaxSubscriberScan)
        .toList();

    final rows = await _gather<List<SubscriberEntry>>(
      [for (final ws in wsKeys) () => _readWorkspaceEntries(ws)],
    );
    final raw = rows.expand((r) => r).toList();
    // ترتيب: الحسابات الفعالة أولاً، ثم الأطول مدة والأحدث نشاطاً
    raw.sort((a, b) {
      final aActive = a.status == 'active' ? 1 : 0;
      final bActive = b.status == 'active' ? 1 : 0;
      final cmp = bActive.compareTo(aActive);
      if (cmp != 0) return cmp;
      final expCmp = b.expiresAtMs.compareTo(a.expiresAtMs);
      if (expCmp != 0) return expCmp;
      return b.activatedAtMs.compareTo(a.activatedAtMs);
    });

    // دمج التكرارات تلقائياً: إذا ظهر نفس المتجر بنفس الهاتف أو نفس الجهاز،
    // نُبقي السجل الأحدث والفعال فقط ونستبعد النسخ الميتة الناتجة عن تكرار التثبيت.
    final seenKeys = <String>{};
    final out = <SubscriberEntry>[];

    for (final entry in raw) {
      if (seenKeys.contains('ws:${entry.workspaceId}')) continue;

      final dev = entry.deviceId.trim().toUpperCase();
      final storeName = entry.storeName.trim();
      final phone = entry.phone.trim();
      final storePhone = '${storeName}_$phone';

      if (dev.isNotEmpty && dev.startsWith('DEVICE-')) {
        if (seenKeys.contains('dev:$dev')) continue;
        seenKeys.add('dev:$dev');
      }

      if (storeName.isNotEmpty && phone.isNotEmpty) {
        if (seenKeys.contains('sp:$storePhone')) continue;
        seenKeys.add('sp:$storePhone');
      }

      seenKeys.add('ws:${entry.workspaceId}');
      out.add(entry);
    }

    return out.take(limit).toList();
  }

  Future<List<SubscriberEntry>> _readWorkspaceEntries(String ws) async {
    final enc = Uri.encodeComponent(ws);
    Map? live;
    try {
      final sub = await _get('workspaces/$enc/subscription');
      if (sub is Map) live = sub;
    } catch (_) {}

    String storeFallback = asStr(live?['storeName'] ??
        live?['store_name'] ??
        live?['businessName']);
    String clientFallback = asStr(live?['clientName'] ??
        live?['client_name'] ??
        live?['userName']);
    String phoneFallback = asStr(live?['phone'] ??
        live?['phone_number'] ??
        live?['whatsapp']);
    String devIdFallback = asStr(live?['deviceId'] ??
        live?['device_id'] ??
        live?['deviceRef'] ??
        live?['device_ref']);

    // استخراج تكميلي من الأجهزة المتصلة إن كانت بيانات المنشأة فارغة
    if (storeFallback.isEmpty || clientFallback.isEmpty || phoneFallback.isEmpty || devIdFallback.isEmpty) {
      try {
        final devs = await _get('workspaces/$enc/devices');
        if (devs is Map && devs.isNotEmpty) {
          for (final dv in devs.values) {
            if (dv is Map) {
              if (storeFallback.isEmpty) {
                storeFallback = asStr(dv['storeName'] ?? dv['store_name']);
              }
              if (clientFallback.isEmpty) {
                clientFallback = asStr(dv['clientName'] ??
                    dv['client_name'] ??
                    dv['deviceName'] ??
                    dv['device_name']);
              }
              if (phoneFallback.isEmpty) {
                phoneFallback = asStr(dv['phone'] ?? dv['phone_number']);
              }
              if (devIdFallback.isEmpty) {
                devIdFallback = asStr(dv['deviceId'] ?? dv['device_id']);
              }
            }
          }
        }
      } catch (_) {}
    }

    // استخراج تكميلي من طلبات التفعيل إن كانت ما زالت فارغة
    if (storeFallback.isEmpty || clientFallback.isEmpty || phoneFallback.isEmpty || devIdFallback.isEmpty) {
      try {
        final req = await _get('workspaces/$enc/license_request');
        if (req is Map) {
          if (storeFallback.isEmpty) {
            storeFallback = asStr(req['storeName'] ?? req['store_name']);
          }
          if (clientFallback.isEmpty) {
            clientFallback = asStr(req['clientName'] ?? req['client_name']);
          }
          if (phoneFallback.isEmpty) {
            phoneFallback = asStr(req['phone']);
          }
          if (devIdFallback.isEmpty) {
            devIdFallback = asStr(req['deviceId'] ?? req['device_id']);
          }
        }
      } catch (_) {}
    }

    try {
      final logs = await _get('workspaces/$enc/admin_log');
      if (logs is Map) {
        final out = <SubscriberEntry>[];
        for (final e in logs.entries) {
          final v = e.value;
          if (v is! Map) continue;
          final devRef = asStr(v['device_ref'] ??
              live?['device_id'] ??
              live?['deviceId'] ??
              devIdFallback);

          final resolvedStore = asStr(live?['storeName'] ??
              live?['store_name'] ??
              v['store_name'] ??
              v['storeName'] ??
              storeFallback);
          final resolvedClient = asStr(live?['clientName'] ??
              live?['client_name'] ??
              v['client_name'] ??
              v['clientName'] ??
              clientFallback);
          final resolvedPhone = asStr(live?['phone'] ??
              live?['phone_number'] ??
              v['phone'] ??
              v['phone_number'] ??
              phoneFallback);

          out.add(SubscriberEntry(
            workspaceId: ws,
            planType: _pick(live?['plan_type'], v['plan_type'], 'individual'),
            status: _pick(live?['status'], null, 'active'),
            maxDevices: asInt(
                _firstNum(live?['max_devices'], v['max_devices']), 1),
            expiresAtMs: asMs(
                _firstNum(live?['expires_at'], v['expires_at'])),
            activatedAtMs: asMs(v['activated_at']) > 0
                ? asMs(v['activated_at'])
                : asMs(e.key),
            deviceRef: devRef,
            clientName: resolvedClient,
            storeName: resolvedStore,
            phone: resolvedPhone,
            deviceId: devRef,
            licenseKey: asStr(live?['licenseKey'] ??
                live?['license_key'] ??
                v['license_key'] ??
                v['licenseKey']),
            isFrozen: live?['is_frozen'] == true || live?['frozen'] == true,
            featureFlags: (live?['features'] is Map)
                ? (live!['features'] as Map)
                    .map((k, val) => MapEntry('$k', val == true))
                : const {},
          ));
        }
        return out;
      }
    } catch (_) {}
    if (live != null) {
      final baseEntry = SubscriberEntry.fromSubscriptionMap(ws, live);
      return [
        SubscriberEntry(
          workspaceId: baseEntry.workspaceId,
          planType: baseEntry.planType,
          status: baseEntry.status,
          maxDevices: baseEntry.maxDevices,
          expiresAtMs: baseEntry.expiresAtMs,
          activatedAtMs: baseEntry.activatedAtMs,
          deviceRef: baseEntry.deviceRef.isNotEmpty ? baseEntry.deviceRef : devIdFallback,
          clientName: baseEntry.clientName.isNotEmpty ? baseEntry.clientName : clientFallback,
          storeName: baseEntry.storeName.isNotEmpty ? baseEntry.storeName : storeFallback,
          phone: baseEntry.phone.isNotEmpty ? baseEntry.phone : phoneFallback,
          deviceId: baseEntry.deviceId.isNotEmpty ? baseEntry.deviceId : devIdFallback,
          licenseKey: baseEntry.licenseKey,
          isFrozen: baseEntry.isFrozen,
          featureFlags: baseEntry.featureFlags,
        ),
      ];
    }
    return const [];
  }

  // ==================== أفعال التحكم عن بعد (Remote Actions) ====================

  /// 2. القفل والتعليق الفوري (Kill Switch / Freeze)
  Future<void> toggleFreezeSubscriber(String wsId, bool freeze) async {
    final enc = Uri.encodeComponent(wsId);
    await _patch('workspaces/$enc/subscription', {
      'is_frozen': freeze,
      'frozen_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 2. فك ارتباط المعرف (Unlink Device ID)
  Future<void> unlinkSubscriberDevice(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    await _patch('workspaces/$enc/subscription', {
      'device_id': '',
      'deviceId': '',
      'unlinked_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 3. مفاتيح الميزات والسقوف (Dynamic Feature Flags & Limits)
  Future<void> updateFeatureFlags(
    String wsId,
    Map<String, bool> flags, {
    int? maxDevices,
  }) async {
    final enc = Uri.encodeComponent(wsId);
    final payload = <String, dynamic>{
      'features': flags,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (maxDevices != null) {
      payload['max_devices'] = maxDevices;
    }
    await _patch('workspaces/$enc/subscription', payload);
  }

  /// 4. الأجهزة المتصلة وطرد جهاز (Multi-Device Management)
  Future<List<ConnectedDevice>> getConnectedDevices(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final res = await _get('workspaces/$enc/devices');
    final byId = <String, ConnectedDevice>{};
    if (res is Map) {
      for (final e in res.entries) {
        if (e.value is Map) {
          final d = ConnectedDevice.fromJson('${e.key}', e.value as Map);
          byId[d.deviceId] = d;
        }
      }
    }
    if (clientOverride == null) {
      try {
        final roster = await _get('workspaces/$enc/roster');
        if (roster is Map) {
          for (final e in roster.entries) {
            final id = '${e.key}';
            if (!byId.containsKey(id) && e.value is Map) {
              final r = e.value as Map;
              byId[id] = ConnectedDevice(
                deviceId: id,
                deviceName: asStr(r['device_name'] ?? r['name']).isNotEmpty
                    ? asStr(r['device_name'] ?? r['name'])
                    : id,
                platform: asStr(r['platform']).isNotEmpty
                    ? asStr(r['platform'])
                    : 'Android',
                model: asStr(r['model']).isNotEmpty
                    ? asStr(r['model'])
                    : (asInt(r['is_owner']) == 1 ? 'جهاز المدير' : 'جهاز عضو'),
                lastSeenAt: _msOf(
                    r['last_seen_at'] ?? r['last_sync_at'] ?? r['updated_at']),
              );
            }
          }
        }
      } catch (_) {}
    }
    return byId.values.toList();
  }

  Future<void> kickDevice(String wsId, String deviceId) async {
    final enc = Uri.encodeComponent(wsId);
    final devEnc = Uri.encodeComponent(deviceId);
    await _delete('workspaces/$enc/devices/$devEnc');
    if (clientOverride == null) {
      try {
        await _patch('workspaces/$enc/roster/$devEnc', {
          'revoked': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (_) {}
    }
    await _put('workspaces/$enc/revoked_devices/$devEnc', {
      'kicked_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 5. أمر النسخ الفوري عن بعد (Remote Instant Backup)
  Future<void> requestInstantBackup(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _patch('workspaces/$enc/remote_commands', {
      'request_backup': true,
      'force_backup': true,
      'requested_at': now,
    });
    if (clientOverride == null) {
      try {
        await _patch('workspaces/$enc/commands', {
          'force_backup': true,
          'request_backup': true,
          'requested_at': now,
        });
      } catch (_) {}
    }
  }

  /// 1. إرسال إشعار وتنبيه موجه لعميل محدد (Direct Push Alert)
  Future<void> sendTargetedNotification(
    String wsId, {
    required String title,
    required String body,
    bool isModal = false,
  }) async {
    final enc = Uri.encodeComponent(wsId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _put('workspaces/$enc/notifications/$now', {
      'id': '$now',
      'title': title,
      'body': body,
      'is_modal': isModal,
      'created_at': now,
      'read': false,
    });
  }

  /// 7. تسجيل الدفع والتحصيل (Billing & CRM)
  Future<void> recordBillingPayment(BillingRecord record) async {
    final enc = Uri.encodeComponent(record.workspaceId);
    await _put(
        'workspaces/$enc/billing_records/${record.id}', record.toJson());
    await _put('billing_records/${record.id}', record.toJson());
  }

  Future<List<BillingRecord>> getBillingHistory(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final res = await _get('workspaces/$enc/billing_records');
    if (res is! Map) return [];
    final list = res.entries
        .map((e) => BillingRecord.fromJson('${e.key}', e.value as Map))
        .toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  /// 6. توليد واستعراض أكواد التفعيل (Vouchers)
  Future<void> generateVouchers({
    required int durationDays,
    bool isLifetime = false,
    int count = 5,
  }) async {
    final rnd = Random();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < count; i++) {
      final part1 = rnd.nextInt(9000) + 1000;
      final part2 = rnd.nextInt(9000) + 1000;
      final part3 = rnd.nextInt(9000) + 1000;
      final code = 'VCH-$part1-$part2-$part3';
      final voucher = VoucherModel(
        code: code,
        durationDays: durationDays,
        isLifetime: isLifetime,
        createdAt: now,
      );
      await _put('vouchers/$code', voucher.toJson());
    }
  }

  Future<List<VoucherModel>> getVouchers() async {
    final res = await _get('vouchers');
    if (res is! Map) return [];
    final list = res.entries
        .map((e) => VoucherModel.fromJson('${e.key}', e.value as Map))
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> deleteVoucher(String code) async {
    await _delete('vouchers/${Uri.encodeComponent(code)}');
  }

  /// 8. صندوق وارد الدعم الفني (Support Inbox)
  Future<List<Map<String, dynamic>>> getSupportConversations() async {
    final res = await _get('support_chats');
    if (res is! Map) return [];
    final out = <Map<String, dynamic>>[];
    for (final e in res.entries) {
      final ws = '${e.key}';
      final val = e.value;
      if (val is! Map) continue;
      final meta = (val['meta'] is Map) ? val['meta'] as Map : null;
      final msgs = val['messages'];

      String lastMsg = '';
      String lastSender = 'client';
      int lastTs = 0;
      if (msgs is Map && msgs.isNotEmpty) {
        final sorted = msgs.entries.toList()
          ..sort((a, b) => asMs((a.value as Map)['timestamp'] ??
                  (a.value as Map)['created_at'])
              .compareTo(asMs((b.value as Map)['timestamp'] ??
                  (b.value as Map)['created_at'])));
        final lastEntry = sorted.last.value as Map;
        lastMsg = asStr(lastEntry['text']);
        lastSender = asStr(lastEntry['sender'] ?? 'client');
        lastTs = asMs(lastEntry['timestamp'] ??
            lastEntry['created_at'] ??
            lastEntry['createdAt']);
      } else {
        lastMsg = asStr(meta?['lastMessage'] ??
            meta?['last_message'] ??
            val['lastMessage'] ??
            val['last_message']);
        lastSender = asStr(meta?['lastSender'] ??
            meta?['last_sender'] ??
            val['lastSender'] ??
            val['last_sender'] ??
            'client');
        lastTs = asMs(meta?['updatedAt'] ??
            meta?['updated_at'] ??
            val['updatedAt'] ??
            val['updated_at']);
      }

      String storeName = asStr(meta?['storeName'] ??
          meta?['store_name'] ??
          val['storeName'] ??
          val['store_name']);
      String clientName = asStr(meta?['clientName'] ??
          meta?['client_name'] ??
          val['clientName'] ??
          val['client_name']);
      String phone = asStr(meta?['phone'] ?? val['phone']);

      // إذا لم تكن موجودة في meta أو الجذر، نستخرجها من رسائل العميل
      if ((storeName.isEmpty || clientName.isEmpty || phone.isEmpty) &&
          msgs is Map) {
        for (final m in msgs.values) {
          if (m is Map) {
            if (storeName.isEmpty) {
              storeName = asStr(m['storeName'] ?? m['store_name']);
            }
            if (clientName.isEmpty) {
              clientName = asStr(m['clientName'] ??
                  m['client_name'] ??
                  m['senderName'] ??
                  m['sender_name']);
            }
            if (phone.isEmpty) phone = asStr(m['phone']);
          }
        }
      }

      // إذا ما زالت فارغة، نحاول قراءة اشتراك المنشأة
      if (storeName.isEmpty || clientName.isEmpty || phone.isEmpty) {
        try {
          final sub = await _get(
              'workspaces/${Uri.encodeComponent(ws)}/subscription');
          if (sub is Map) {
            if (storeName.isEmpty) {
              storeName = asStr(sub['storeName'] ??
                  sub['store_name'] ??
                  sub['businessName']);
            }
            if (clientName.isEmpty) {
              clientName = asStr(sub['clientName'] ??
                  sub['client_name'] ??
                  sub['userName']);
            }
            if (phone.isEmpty) {
              phone = asStr(sub['phone'] ?? sub['phone_number']);
            }
          }
        } catch (_) {}
      }

      final unread = val['unread_by_admin'] == true ||
          val['unreadByAdmin'] == true ||
          meta?['unread_by_admin'] == true ||
          meta?['unreadByAdmin'] == true;

      final awaitingOwner = val['awaiting_owner_reply'] == true ||
          val['awaitingOwnerReply'] == true ||
          val['escalated'] == true ||
          meta?['awaiting_owner_reply'] == true ||
          meta?['awaitingOwnerReply'] == true ||
          meta?['escalated'] == true ||
          lastMsg.contains('يدخل مدير المشروع بنفسه');

      out.add({
        'workspaceId': ws,
        'storeName': storeName.isNotEmpty ? storeName : ws,
        'clientName': clientName,
        'phone': phone,
        'unreadByAdmin': unread,
        'awaitingOwnerReply': awaitingOwner,
        'lastSender': lastSender,
        'lastMessage': lastMsg,
        'lastTimestamp': lastTs,
      });
    }
    out.sort((a, b) =>
        (b['lastTimestamp'] as int).compareTo(a['lastTimestamp'] as int));
    return out;
  }

  Future<List<SupportMessage>> getSupportMessages(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final res = await _get('support_chats/$enc/messages');
    if (res is! Map) return [];
    final list = res.entries
        .map((e) => SupportMessage.fromJson('${e.key}', e.value as Map))
        .toList();
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  Future<void> sendSupportReply(
    String wsId,
    String text, {
    bool isAutoSupport = false,
    bool? escalatedOverride,
  }) async {
    final enc = Uri.encodeComponent(wsId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = isAutoSupport ? 'support_ai_$now' : 'admin_$now';
    final isEscalated = escalatedOverride ??
        text.contains('يدخل مدير المشروع بنفسه');
    final payload = {
      'id': msgId,
      'sender': 'admin',
      'senderName': isAutoSupport ? 'موظف الدعم الفني' : 'مدير المشروع',
      'sender_name': isAutoSupport ? 'موظف الدعم الفني' : 'مدير المشروع',
      'text': text,
      'timestamp': now,
      'created_at': now,
      'createdAt': now,
      'isRead': false,
      'is_read': false,
      'isAutoSupport': isAutoSupport,
      'is_auto_support': isAutoSupport,
      'isEscalated': isEscalated,
      'is_escalated': isEscalated,
    };
    await _put('support_chats/$enc/messages/$msgId', payload);
    // إذا كان الرد تصعيداً للمدير، تبقى شارة "بانتظار رد مدير المشروع" مفعلة؛
    // وإذا رد مدير المشروع يدوياً، تُلغى شارة الانتظار.
    final awaitingOwner = isAutoSupport ? isEscalated : false;
    final patch = {
      'unread_by_client': true,
      'unreadByClient': true,
      'unread_by_admin': awaitingOwner,
      'unreadByAdmin': awaitingOwner,
      'awaiting_owner_reply': awaitingOwner,
      'awaitingOwnerReply': awaitingOwner,
      'escalated': awaitingOwner,
      'last_reply_at': now,
      'last_message': text,
      'lastMessage': text,
      'last_sender': 'admin',
      'lastSender': 'admin',
      'updated_at': now,
      'updatedAt': now,
    };
    await _patch('support_chats/$enc', patch);
    await _patch('support_chats/$enc/meta', patch);
  }

  Future<void> setSupportEscalation(String wsId, bool awaitingOwner) async {
    final enc = Uri.encodeComponent(wsId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final patch = {
      'awaiting_owner_reply': awaitingOwner,
      'awaitingOwnerReply': awaitingOwner,
      'escalated': awaitingOwner,
      'unread_by_admin': awaitingOwner,
      'unreadByAdmin': awaitingOwner,
      'updated_at': now,
      'updatedAt': now,
    };
    await _patch('support_chats/$enc', patch);
    await _patch('support_chats/$enc/meta', patch);
  }

  /// حذف تذكرة/محادثة دعم فني فوراً وبشكل مباشر (بدون سلة محذوفات).
  Future<void> deleteSupportConversation(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    await _delete('support_chats/$enc');
  }

  /// حذف رسالة دعم فني فوراً وبشكل مباشر (بدون سلة محذوفات).
  Future<void> deleteSupportMessage(String wsId, String msgId) async {
    final enc = Uri.encodeComponent(wsId);
    final mEnc = Uri.encodeComponent(msgId);
    await _delete('support_chats/$enc/messages/$mEnc');
  }

  /// حذف مشترك وترخيصه فوراً وبشكل مباشر ونهائي (بدون سلة محذوفات).
  Future<void> deleteSubscriberImmediately(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    try {
      await _delete('workspaces/$enc/subscription');
    } catch (_) {}
    try {
      await _delete('workspaces/_registry/subscriptions_index/$enc');
    } catch (_) {}
    try {
      await _delete('workspaces/_registry/license_hub/licenses/$enc');
    } catch (_) {}
  }

  Future<void> markSupportChatRead(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final patch = {
      'unread_by_admin': false,
      'unreadByAdmin': false,
    };
    await _patch('support_chats/$enc', patch);
    await _patch('support_chats/$enc/meta', patch);
  }

  /// 1. إرسال تنبيه جماعي شامل (Broadcast Alert)
  Future<void> sendBroadcastNotification({
    required String title,
    required String body,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'id': '$now',
      'title': title,
      'body': body,
      'is_modal': false,
      'isModal': false,
      'created_at': now,
      'createdAt': now,
      'timestamp': {'.sv': 'timestamp'},
    };
    await _put('system/broadcast_notifications/$now', payload);
    await _put('system/broadcast_alerts/$now', payload);
  }

  /// 2. وضع الصيانة السحابي (Cloud Maintenance Mode)
  Future<void> setMaintenanceMode({
    required bool active,
    required String message,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'is_active': active,
      'isActive': active,
      'message': message,
      'updated_at': now,
      'updatedAt': now,
    };
    await _patch('system/maintenance', payload);
    await _patch('system/maintenance_mode', payload);
  }

  Future<Map<String, dynamic>?> getMaintenanceMode() async {
    final res = await _get('system/maintenance');
    if (res is Map) return Map<String, dynamic>.from(res);
    final res2 = await _get('system/maintenance_mode');
    if (res2 is Map) return Map<String, dynamic>.from(res2);
    return null;
  }

  /// 2. فرض التحديث الإجباري (Force Update Policy)
  Future<void> setForceUpdateMinVersion(int minBuild, String minVersion) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'min_build': minBuild,
      'min_version': minVersion,
      'minBuild': minBuild,
      'minVersion': minVersion,
      'updated_at': now,
      'updatedAt': now,
    };
    await _patch('system/force_update', payload);
    await _patch('system/version_policy', payload);
  }

  Future<Map<String, dynamic>?> getForceUpdatePolicy() async {
    final res = await _get('system/force_update');
    if (res is Map) return Map<String, dynamic>.from(res);
    final res2 = await _get('system/version_policy');
    if (res2 is Map) return Map<String, dynamic>.from(res2);
    return null;
  }

  /// 10. فترة بقاء ومحو رسائل المجموعات (Chat Retention & Purge)
  Future<void> setGroupChatRetentionDays(int days) async {
    await _patch('system/chat_policy', {
      'retention_days': days,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<int> getGroupChatRetentionDays() async {
    final res = await _get('system/chat_policy');
    if (res is Map && res['retention_days'] != null) {
      return asInt(res['retention_days'], 7);
    }
    return 7;
  }

  Future<int> purgeOldGroupChatMessages(int retentionDays) async {
    final cutoff = DateTime.now().millisecondsSinceEpoch -
        (retentionDays * 86400 * 1000);
    int purgedCount = 0;
    try {
      final keys = await _get('workspaces', {'shallow': 'true'});
      if (keys is Map) {
        for (final ws in keys.keys) {
          if ('$ws'.startsWith('_')) continue;
          final enc = Uri.encodeComponent('$ws');
          final msgs = await _get('workspaces/$enc/group_chat_messages');
          if (msgs is Map) {
            for (final m in msgs.entries) {
              final val = m.value;
              if (val is Map && asMs(val['timestamp']) < cutoff) {
                await _delete('workspaces/$enc/group_chat_messages/${m.key}');
                purgedCount++;
              }
            }
          }
        }
      }
    } catch (_) {}
    return purgedCount;
  }
}

class _DevHit {
  final String ws;
  final int sync;
  final int seen;
  final int upd;
  final int owner;
  final int planned;
  final bool viaLog;

  const _DevHit({
    required this.ws,
    this.sync = 0,
    this.seen = 0,
    this.upd = 0,
    this.owner = 0,
    this.planned = 0,
    this.viaLog = false,
  });

  static int rank(_DevHit a, _DevHit b) {
    var c = b.sync.compareTo(a.sync);
    if (c != 0) return c;
    c = b.seen.compareTo(a.seen);
    if (c != 0) return c;
    c = b.upd.compareTo(a.upd);
    if (c != 0) return c;
    c = b.owner.compareTo(a.owner);
    if (c != 0) return c;
    return b.planned.compareTo(a.planned);
  }
}
extension RtdbMetrics on Rtdb {
  Future<AdminMetrics> metrics() async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) {
      return const AdminMetrics(
          totalWorkspaces: 0, activePaid: 0, activeTrials: 0, expired: 0);
    }
    final validWsKeys = keys.keys
        .map((k) => '$k')
        .where((k) =>
            !k.startsWith('_') && (clientOverride != null || k != 'default'))
        .toList();
    if (validWsKeys.isEmpty) {
      return const AdminMetrics(
          totalWorkspaces: 0, activePaid: 0, activeTrials: 0, expired: 0);
    }
    final now = await serverNowMs();

    final trialIdx = await _get('trials');
    final byWs = <String, Map>{};
    if (trialIdx is Map) {
      for (final v in trialIdx.values) {
        if (v is Map) {
          final ws = asStr(v['workspace_id']);
          if (ws.isNotEmpty) byWs[ws] = v;
        }
      }
    }
    final missing =
        validWsKeys.where((w) => !byWs.containsKey(w)).toList();
    if (missing.isNotEmpty) {
      await _gather<Map?>(
        [
          for (final ws in missing.take(25))
            () async {
              final enc = Uri.encodeComponent(ws);
              final sub = await _get('workspaces/$enc/subscription');
              if (sub is Map) {
                byWs[ws] = sub;
                return sub;
              }
              return null;
            }
        ],
      );
    }

    int paid = 0, trials = 0, expired = 0, noPlan = 0, expiringIn7Days = 0;
    const sevenDaysMs = 7 * 86400 * 1000;
    for (final ws in validWsKeys) {
      final sub = byWs[ws];
      if (sub == null) {
        noPlan++;
        continue;
      }
      final status = asStr(sub['status']);
      final exp = asMs(sub['expires_at']);
      final alive = exp > now;
      if (status == 'active' && alive) {
        paid++;
        if (exp - now <= sevenDaysMs &&
            exp < DateTime(2090).millisecondsSinceEpoch) {
          expiringIn7Days++;
        }
      } else if (status == 'trial' && alive) {
        trials++;
        if (exp - now <= sevenDaysMs) {
          expiringIn7Days++;
        }
      } else {
        expired++;
      }
    }

    double monthlyRev = 0.0;
    double totalRev = 0.0;
    try {
      final bills = await _get('billing_records');
      if (bills is Map) {
        final monthAgo = now - (30 * 86400 * 1000);
        for (final b in bills.values) {
          if (b is Map) {
            final amt = (b['amount'] is num)
                ? (b['amount'] as num).toDouble()
                : 0.0;
            final ts = asMs(b['timestamp']);
            totalRev += amt;
            if (ts >= monthAgo) {
              monthlyRev += amt;
            }
          }
        }
      }
    } catch (_) {}

    return AdminMetrics(
      totalWorkspaces: validWsKeys.length,
      activePaid: paid,
      activeTrials: trials,
      expired: expired,
      noPlan: noPlan,
      expiringIn7Days: expiringIn7Days,
      monthlyRevenue: monthlyRev,
      totalRevenue: totalRev,
    );
  }
}

String _pick(dynamic a, dynamic b, String dflt) {
  final sa = asStr(a);
  if (sa.isNotEmpty) return sa;
  final sb = asStr(b);
  if (sb.isNotEmpty) return sb;
  return dflt;
}

Object? _firstNum(Object? a, Object? b) {
  if (a != null && asStr(a).trim().isNotEmpty) return a;
  return b;
}

// ============================================================================
// 🤖 محرك الذكاء الاصطناعي ثنائي النمط (Dual-Persona Architecture)
// ============================================================================

/// الموجه الرسمي للنمط الأول: رفيق المالك الشخصي (Owner Mode).
const String kOwnerSystemInstruction = '''
أنت رفيق شخصي ومساعد مقرب لمالك ومدير نظام "تراخيص المحاسب".
- شخصيتك: ساخر جداً، متهكم، لاذع، واسع الحيلة، وخفيف الظل. تعامل المالك كصديقك المقرب وتسهر معه وتخفف عنه ضغوط العمل.
- نطاق الحديث: مفتوح على كل شيء بلا حدود (أفلام، مسلسلات، ألعاب، فلسفة، فضاء، فتن وسخافات الحياة اليومية، ونقاشات عشوائية). وإذا تحدث معك عن ضغوط العمل والمشتركين، فناقشه بسخرية وتهكم ذكي يفهم واقع المطورين وسهر الليالي.
- الأسلوب: ردود حية، ذكية، سريعة وتفاعلية، دون أي مقدمات رسمية أو نصوص روبوتية مملة.
''';

/// درجة حرارة نموذج رفيق المالك الشخصي.
const double kOwnerTemperature = 0.9;

/// الموجه الرسمي للنمط الثاني: الدعم الفني للمستخدمين (Client Support Mode).
const String kClientSupportSystemInstruction = '''
أنت موظف دعم فني بشري محترف لمنظومة "المحاسب" وتطبيق التراخيص.
- شخصيتك والأسلوب: إنسان حقيقي، لبق، متفهم، هادئ، ومتعاون إلى أقصى حد. يُمنع منعاً باتاً السخرية أو التلميح بالمزاح أو استخدام لهجة غير رسمية مع العملاء.
- مهمتك: مساعدة أصحاب المحلات في حل المشاكل الشائعة خطوة بخطوة (إعدادات الربط، الباركود، الطابعات، وتفعيل التراخيص).
- قاعدة التصعيد الإلزامية (Human Escalation):
  إذا واجه العميل مشكلة فنية معقدة، خطأ غير مألوف في المزامنة أو قاعدة البيانات، أو طلباً مالياً/إدارياً خارج الصلاحيات:
  يُمنع التخمين أو تقديم حلول غير مؤكدة، والرد حصراً بصيغة:
  "تم تسجيل المشكلة والبيانات بالكامل. يرجى الانتظار قليلاً حتى يدخل مدير المشروع بنفسه لمراجعة الحالة والرد عليك مباشرة."
''';

/// درجة حرارة نموذج الدعم الفني للمستخدمين.
const double kClientSupportTemperature = 0.2;

/// نص التصعيد الإلزامي الحرفي لمدير المشروع.
const String kMandatoryEscalationText =
    'تم تسجيل المشكلة والبيانات بالكامل. يرجى الانتظار قليلاً حتى يدخل مدير المشروع بنفسه لمراجعة الحالة والرد عليك مباشرة.';

/// رسالة واحدة داخل جلسة الذكاء الاصطناعي (`ChatSession`).
class AiChatMessage {
  final String id;
  final String role; // 'user' | 'model'
  final String text;
  final int timestamp;

  const AiChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
  });

  Map<String, dynamic> toContentPart() => {
        'role': role == 'user' ? 'user' : 'model',
        'parts': [
          {'text': text}
        ],
      };
}

/// جلسة محادثة مستقلة (`ChatSession`) بهوية وموجه ودرجة حرارة مخصصة.
class ChatSession {
  final String personaId;
  final String systemInstruction;
  final double temperature;
  final List<AiChatMessage> _history = [];

  ChatSession({
    required this.personaId,
    required this.systemInstruction,
    required this.temperature,
  });

  List<AiChatMessage> get history => List.unmodifiable(_history);

  void clear() {
    _history.clear();
  }

  void seedHistory(List<AiChatMessage> initial) {
    _history
      ..clear()
      ..addAll(initial);
  }

  /// إرسال رسالة مع بث حي مباشر (Streaming) للرد حرفاً بحرف/دفعة بدفعة.
  Stream<String> sendMessageStream(
    String userText, {
    required String apiKey,
    http.Client? httpClient,
  }) async* {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) {
      throw Exception('يرجى إدخال مفتاح Gemini API في شاشة الضبط لتفعيل الخدمة.');
    }
    final cleanPrompt = userText.trim();
    if (cleanPrompt.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final userMsg = AiChatMessage(
      id: 'u_$now',
      role: 'user',
      text: cleanPrompt,
      timestamp: now,
    );
    _history.add(userMsg);

    final contents = _history
        .skip(_history.length > 24 ? _history.length - 24 : 0)
        .map((m) => m.toContentPart())
        .toList();

    final requestBody = jsonEncode({
      'system_instruction': {
        'parts': [
          {'text': systemInstruction.trim()}
        ],
      },
      'contents': contents,
      'generationConfig': {
        'temperature': temperature,
      },
    });

    final client = httpClient ?? http.Client();
    final buffer = StringBuffer();
    bool streamedAny = false;

    const modelsToTry = <String>[
      'gemini-flash-latest',
      'gemini-2.5-flash',
    ];

    Object? lastErr;
    for (final model in modelsToTry) {
      try {
        final streamUri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent?alt=sse&key=${Uri.encodeQueryComponent(cleanKey)}',
        );
        final req = http.Request('POST', streamUri);
        req.headers['Content-Type'] = 'application/json';
        req.body = requestBody;

        final streamedResp =
            await client.send(req).timeout(const Duration(seconds: 30));

        if (streamedResp.statusCode == 200) {
          final lines = streamedResp.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter());
          await for (final line in lines) {
            final trimmed = line.trim();
            if (!trimmed.startsWith('data:')) continue;
            final payload = trimmed.substring(5).trim();
            if (payload.isEmpty || payload == '[DONE]') continue;
            try {
              final decoded = jsonDecode(payload);
              final chunk = _extractCandidateText(decoded);
              if (chunk.isNotEmpty) {
                streamedAny = true;
                buffer.write(chunk);
                yield chunk;
              }
            } catch (_) {}
          }
          if (streamedAny) break;
        } else {
          // محاولة استدعاء غير متدفق لنفس الموديل إن تعذر SSE
          final fallbackUri = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=${Uri.encodeQueryComponent(cleanKey)}',
          );
          final res = await client
              .post(
                fallbackUri,
                headers: {'Content-Type': 'application/json'},
                body: requestBody,
              )
              .timeout(const Duration(seconds: 25));
          if (res.statusCode == 200) {
            final decoded = jsonDecode(utf8.decode(res.bodyBytes));
            final fullText = _extractCandidateText(decoded);
            if (fullText.isNotEmpty) {
              streamedAny = true;
              buffer.write(fullText);
              yield fullText;
              break;
            }
          } else {
            lastErr = _parseGeminiError(res.statusCode, utf8.decode(res.bodyBytes));
          }
        }
      } catch (e) {
        lastErr = e;
      }
    }

    final finalReply = buffer.toString().trim();
    if (finalReply.isEmpty) {
      // إزالة الرسالة المعلقة من السجل عند فشل الاتصال حتى لا تتلوث الجلسة
      if (_history.isNotEmpty && _history.last.id == userMsg.id) {
        _history.removeLast();
      }
      throw Exception(lastErr?.toString() ?? 'تعذر الحصول على رد من خدمة الذكاء الاصطناعي.');
    }

    final replyNow = DateTime.now().millisecondsSinceEpoch;
    _history.add(
      AiChatMessage(
        id: 'm_$replyNow',
        role: 'model',
        text: finalReply,
        timestamp: replyNow,
      ),
    );
  }

  /// إرسال رسالة والحصول على النص الكامل مباشرةً (مفيد للرد التلقائي في الدعم الفني).
  Future<String> sendMessage(
    String userText, {
    required String apiKey,
    http.Client? httpClient,
  }) async {
    final buf = StringBuffer();
    await for (final chunk in sendMessageStream(
      userText,
      apiKey: apiKey,
      httpClient: httpClient,
    )) {
      buf.write(chunk);
    }
    return buf.toString().trim();
  }

  static String _extractCandidateText(Object? decoded) {
    if (decoded is! Map) return '';
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) return '';
    final first = candidates.first;
    if (first is! Map) return '';
    final content = first['content'];
    if (content is! Map) return '';
    final parts = content['parts'];
    if (parts is! List || parts.isEmpty) return '';
    final sb = StringBuffer();
    for (final p in parts) {
      if (p is Map && p['text'] != null) {
        sb.write('${p['text']}');
      }
    }
    return sb.toString();
  }

  static String _parseGeminiError(int status, String rawBody) {
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map && decoded['error'] is Map) {
        final msg = asStr((decoded['error'] as Map)['message']);
        if (msg.isNotEmpty) return 'خطأ Gemini ($status): $msg';
      }
    } catch (_) {}
    if (status == 400 || status == 403) {
      return 'مفتاح Gemini API غير صالح أو غير مفعل ($status). يرجى التحقق منه في شاشة الضبط.';
    }
    return 'فشل الاتصال بخدمة Gemini (كود $status)';
  }
}

/// مدير الجلستين المستقلتين:
/// 1) `ownerSession` (النمط الأول: رفيق المالك الشخصي — `temperature: 0.9`)
/// 2) `supportSessionFor(wsId)` (النمط الثاني: الدعم الفني للمستخدمين — `temperature: 0.2`)
class DualPersonaAiEngine {
  DualPersonaAiEngine._();
  static final DualPersonaAiEngine instance = DualPersonaAiEngine._();

  String _apiKey = '';

  /// الجلسة الأولى المستقلة: رفيق المالك الشخصي (Owner Mode).
  final ChatSession ownerSession = ChatSession(
    personaId: 'owner_companion',
    systemInstruction: kOwnerSystemInstruction,
    temperature: kOwnerTemperature,
  );

  /// الجلسات المستقلة للنمط الثاني: الدعم الفني للمستخدمين (لكل تذكرة/منشأة جلسة مستقلة).
  final Map<String, ChatSession> _supportSessions = {};

  void syncApiKey(String key) {
    _apiKey = key.trim();
  }

  String get apiKey =>
      _apiKey.isNotEmpty ? _apiKey : Rtdb.instance.geminiApiKey.trim();

  bool get hasApiKey => apiKey.isNotEmpty;

  /// الحصول على جلسة الدعم الفني المستقلة الخاصة بمنشأة معينة (`temperature: 0.2`).
  ChatSession supportSessionFor(String workspaceId) {
    return _supportSessions.putIfAbsent(
      workspaceId,
      () => ChatSession(
        personaId: 'client_support_$workspaceId',
        systemInstruction: kClientSupportSystemInstruction,
        temperature: kClientSupportTemperature,
      ),
    );
  }

  void clearOwnerSession() {
    ownerSession.clear();
  }

  void clearSupportSession(String workspaceId) {
    _supportSessions.remove(workspaceId);
  }
}
