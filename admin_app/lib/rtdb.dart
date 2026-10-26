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

const int kMaxWorkspaceScan = 250;
const int kMaxSubscriberScan = 250;

const String kOfficialAdminUid = 'mTMmR6MDBMZH8nKEbvCntRemkq73';

/// رمز التحديث الدائم لهوية المشرف (Owner) يُقرأ حصرياً من متغير البناء الآمن وقت التشغيل/البناء.
const String kAdminRefreshTokenDefault = String.fromEnvironment(
  'ADMIN_REFRESH_TOKEN',
);

/// رسالة خطأ واضحة عند تشغيل تطبيق الإدارة محلياً دون تمرير متغير البناء ADMIN_REFRESH_TOKEN.
const String kMissingAdminRefreshTokenError =
    'خطأ في إعداد بيئة المشرف: لم يتم تمرير المتغير ADMIN_REFRESH_TOKEN عند تشغيل التطبيق محلياً. '
    'يرجى التشغيل عبر --dart-define=ADMIN_REFRESH_TOKEN=<TOKEN> أو إدخال رمز المشرف في إعدادات الاتصال.';

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
  static const kDeepSeekApiKeyPref = 'deepseek_api_key';
  static const kAiApiKeyPref = 'ai_api_key';
  static const kAiBaseUrlPref = 'ai_base_url';
  static const kAiModelPref = 'ai_model_id';
  static const kAiSystemPromptPref = 'ai_system_prompt';
  static const kAutoSupportPref = 'auto_support_enabled';

  String deepSeekApiKey = '';
  String aiBaseUrl = kDefaultAiEndpoint;
  String aiModelId = kDefaultAiModel;
  String aiSystemPrompt = kOwnerSystemInstruction;
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
    return clean != 'workspaces' &&
        !clean.startsWith('workspaces/') &&
        clean != 'system' &&
        !clean.startsWith('system/');
  }

  static String _toRegistryPath(String path) {
    final clean = path.replaceAll(RegExp(r'^/+'), '');
    return 'workspaces/_registry/$clean';
  }

  bool get isAdminTokenMissing =>
      adminRefreshToken.trim().isEmpty &&
      kAdminRefreshTokenDefault.trim().isEmpty &&
      authToken.trim().isEmpty;

  Future<void> load() async {
    _useRegistryFallback = false;
    _anonAuthFailed = false;
    _adminAuthFailed = false;
    final sp = await SharedPreferences.getInstance();
    baseUrl = (sp.getString(_kUrl) ?? '').trim();
    if (baseUrl.isEmpty) baseUrl = kOfficialRtdbUrl;
    authToken = (sp.getString(_kAuth) ?? '').trim();
    adminRefreshToken = (sp.getString(_kAdminRt) ?? '').trim();
    if (adminRefreshToken.isEmpty || adminRefreshToken.startsWith('GUEST-')) {
      adminRefreshToken = kAdminRefreshTokenDefault.trim();
    }
    if (adminRefreshToken.isEmpty && authToken.isEmpty) {
      lastAuthError = kMissingAdminRefreshTokenError;
    } else {
      lastAuthError = '';
    }
    adminUid = sp.getString(_kAdminUid) ?? '';
    _idToken = sp.getString(_kIdToken) ?? '';
    _refreshToken = sp.getString(_kRefresh) ?? '';
    _expiryMs = sp.getInt(_kExpiry) ?? 0;

    final storedAiKey = (sp.getString(kAiApiKeyPref) ?? '').trim();
    final storedGeminiKey = (sp.getString('gemini_api_key') ?? '').trim();
    final storedDeepSeekKey = (sp.getString(kDeepSeekApiKeyPref) ?? '').trim();
    deepSeekApiKey = storedAiKey.isNotEmpty
        ? storedAiKey
        : (storedGeminiKey.isNotEmpty ? storedGeminiKey : storedDeepSeekKey);

    final storedBaseUrl = (sp.getString(kAiBaseUrlPref) ?? '').trim();
    aiBaseUrl = storedBaseUrl.isNotEmpty ? storedBaseUrl : kDefaultAiEndpoint;

    final storedModel = (sp.getString(kAiModelPref) ?? '').trim();
    aiModelId = storedModel.isNotEmpty ? storedModel : kDefaultAiModel;

    final storedPrompt = (sp.getString(kAiSystemPromptPref) ?? '').trim();
    aiSystemPrompt =
        storedPrompt.isNotEmpty ? storedPrompt : kOwnerSystemInstruction;

    autoSupportEnabled = sp.getBool(kAutoSupportPref) ?? true;
    DualPersonaAiEngine.instance.syncSettings(
      apiKey: deepSeekApiKey,
      baseUrl: aiBaseUrl,
      modelId: aiModelId,
      systemPrompt: aiSystemPrompt,
    );

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

  Future<void> saveDeepSeekApiKey(String key) async {
    deepSeekApiKey = key.trim();
    final sp = await SharedPreferences.getInstance();
    if (deepSeekApiKey.isEmpty) {
      await sp.remove(kDeepSeekApiKeyPref);
      await sp.remove(kAiApiKeyPref);
      await sp.remove('gemini_api_key');
    } else {
      await sp.setString(kDeepSeekApiKeyPref, deepSeekApiKey);
      await sp.setString(kAiApiKeyPref, deepSeekApiKey);
      await sp.setString('gemini_api_key', deepSeekApiKey);
    }
    DualPersonaAiEngine.instance.syncApiKey(deepSeekApiKey);
  }

  Future<void> saveGeminiApiKey(String key) => saveDeepSeekApiKey(key);

  Future<void> saveAiSettings({
    String? baseUrl,
    String? apiKey,
    String? modelId,
    String? systemPrompt,
  }) async {
    final sp = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      final cleanUrl = baseUrl.trim();
      aiBaseUrl = cleanUrl.isEmpty ? kDefaultAiEndpoint : cleanUrl;
      await sp.setString(kAiBaseUrlPref, aiBaseUrl);
    }
    if (apiKey != null) {
      deepSeekApiKey = apiKey.trim();
      if (deepSeekApiKey.isEmpty) {
        await sp.remove(kDeepSeekApiKeyPref);
        await sp.remove(kAiApiKeyPref);
        await sp.remove('gemini_api_key');
      } else {
        await sp.setString(kDeepSeekApiKeyPref, deepSeekApiKey);
        await sp.setString(kAiApiKeyPref, deepSeekApiKey);
        await sp.setString('gemini_api_key', deepSeekApiKey);
      }
    }
    if (modelId != null) {
      final cleanModel = modelId.trim();
      aiModelId = cleanModel.isEmpty ? kDefaultAiModel : cleanModel;
      await sp.setString(kAiModelPref, aiModelId);
    }
    if (systemPrompt != null) {
      final cleanPrompt = systemPrompt.trim();
      aiSystemPrompt =
          cleanPrompt.isEmpty ? kOwnerSystemInstruction : cleanPrompt;
      await sp.setString(kAiSystemPromptPref, aiSystemPrompt);
    }
    DualPersonaAiEngine.instance.syncSettings(
      apiKey: deepSeekApiKey,
      baseUrl: aiBaseUrl,
      modelId: aiModelId,
      systemPrompt: aiSystemPrompt,
    );
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
    // 1. تصحيح أي رمز تحديث أُلصق في authToken — اللصق فعل مقصود من
    // المستخدم فيحل محل الرمز الحالي مهما كان (بما فيه الافتراضي المضمّن)
    // ويُعاد ضبط حالة فشل المصادقة لتجربة الهوية الجديدة فورًا.
    if (authToken.trim().startsWith('AMf-')) {
      final rt = authToken.trim().replaceAll(RegExp(r'\s+'), '');
      authToken = '';
      if (rt != adminRefreshToken) {
        adminRefreshToken = rt;
        _adminAuthFailed = false;
        _idToken = '';
        _expiryMs = 0;
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_kAdminRt, adminRefreshToken);
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

  /// تنفيذ طلب HTTP DELETE صارم يتحقق من أن كود استجابة Firebase هو 200 OK حصراً.
  /// في حال الفشل، يرمي استثناءً يتضمن كود الاستجابة الفعلي ورسالة الخطأ من الخادم.
  Future<int> _deleteStrict200(String path, {bool allowRegistryFallback = false}) async {
    final targetPath = (allowRegistryFallback &&
            _useRegistryFallback &&
            _canFallbackToRegistry(path))
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
          allowRegistryFallback &&
          _canFallbackToRegistry(path)) {
        _useRegistryFallback = true;
        final regPath = _toRegistryPath(path);
        r = await _http
            .delete(await _u(regPath))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200) {
      throw _fail('حذف', path, r.statusCode, r.body);
    }
    return r.statusCode;
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

  /// تحويل المدخل إلى معرف مساحة عمل — يقبل تلقائياً:
  ///  1) بصمة التفعيل (32 خانة hex) ⇒ فهرس trials/(fp).
  ///  2) رقم الهاتف ⇒ بحث في /trials و /workspaces/{ws}/subscription.
  ///  3) معرف الجهاز (DEVICE-XXXXXXXX) ⇒ بحث في /trials و roster كل المساحات.
  ///  4) معرف مساحة العمل مباشرة ⇒ تحقق من وجود العقدة أو الفهرس.
  Future<String> resolveWorkspaceId(String input) async {
    final id = input.trim();
    if (id.isEmpty) throw Exception('أدخل معرف الجهاز أو مساحة العمل أولاً');

    // (1) بصمة تفعيل 32-hex.
    if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id)) {
      final t = await _get('trials/${Uri.encodeComponent(id)}');
      if (t is Map) {
        final ws = asStr(t['workspace_id'] ?? t['workspaceId']);
        if (ws.isNotEmpty) return ws;
        final dev = asStr(t['device_id'] ?? t['deviceId']);
        if (dev.isNotEmpty && clientOverride == null) {
          final cleanDev = dev.toUpperCase().replaceAll(RegExp(r'[.#$\[\]/]'), '_');
          return 'ws_$cleanDev';
        }
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
      final rawHex = normKey.substring(3).replaceAll('-', '');
      final derivedDevId = 'DEVICE-$rawHex';
      // الأولوية القصوى: فهرس device_index يحدد المنشأة النشطة حالياً على جهاز العميل
      // (عندما يمتلك العميل عدة منشآت على نفس الجهاز، يشترك الكل بنفس NX-XXXX).
      if (clientOverride == null) {
        try {
          final directIdx = await _get(
              'workspaces/_registry/device_index/${Uri.encodeComponent(derivedDevId)}');
          if (directIdx is Map) {
            final ws =
                asStr(directIdx['workspace_id'] ?? directIdx['workspaceId']);
            if (ws.isNotEmpty) return ws;
          }
        } catch (_) {}
      }
      try {
        final trials = await _get('trials');
        if (trials is Map) {
          String bestWs = '';
          int bestTs = -1;
          for (final v in trials.values) {
            if (v is! Map) continue;
            final k = asStr(v['licenseKey'] ?? v['license_key']).toUpperCase();
            final ws = asStr(v['workspace_id'] ?? v['workspaceId']);
            if (k == normKey && ws.isNotEmpty) {
              final ts = asMs(v['requested_at'] ?? v['updated_at'] ?? v['created_at']);
              final isUnactivated = asStr(v['status']) == 'unactivated' ? 1 : 0;
              final score = ts + (isUnactivated * 1000000000000);
              if (bestWs.isEmpty || score >= bestTs) {
                bestWs = ws;
                bestTs = score;
              }
            }
          }
          if (bestWs.isNotEmpty) return bestWs;
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
      return await resolveWorkspaceId(derivedDevId);
    }

    // (1-د) إن كان الإدخال رقم هاتف، نبحث عنه في /trials ثم في /workspaces/{ws}/subscription
    final normPhone = normalizeSubscriberPhone(id);
    final looksLikePhone = normPhone.isNotEmpty &&
        RegExp(r'^[\+\d\s\-\(\)]{7,18}$').hasMatch(id);
    if (looksLikePhone) {
      try {
        final trials = await _get('trials');
        if (trials is Map) {
          String bestWs = '';
          int bestTs = -1;
          for (final v in trials.values) {
            if (v is! Map) continue;
            final p = normalizeSubscriberPhone(
                asStr(v['phone'] ?? v['phone_number'] ?? v['whatsapp']));
            final ws = asStr(v['workspace_id'] ?? v['workspaceId']);
            if (p == normPhone && ws.isNotEmpty) {
              final ts = asMs(v['updated_at'] ?? v['activated_at'] ?? v['expires_at']);
              if (bestWs.isEmpty || ts >= bestTs) {
                bestWs = ws;
                bestTs = ts;
              }
            }
          }
          if (bestWs.isNotEmpty) return bestWs;
        }
      } catch (_) {}

      try {
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
        final matched = await _gather<MapEntry<String, int>>(
          [
            for (final ws in wsKeys)
              () async {
                final enc = Uri.encodeComponent(ws);
                final sub = await _get('workspaces/$enc/subscription');
                if (sub is Map) {
                  final p = normalizeSubscriberPhone(asStr(
                      sub['phone'] ?? sub['phone_number'] ?? sub['whatsapp']));
                  if (p == normPhone) {
                    return MapEntry(
                      ws,
                      asMs(sub['expires_at'] ?? sub['activated_at']),
                    );
                  }
                }
                if (clientOverride == null) {
                  final req = await _get('workspaces/$enc/license_request');
                  if (req is Map) {
                    final p = normalizeSubscriberPhone(asStr(req['phone']));
                    if (p == normPhone) {
                      return MapEntry(ws, asMs(req['created_at']));
                    }
                  }
                }
                return null;
              }
          ],
        );
        if (matched.isNotEmpty) {
          matched.sort((a, b) => b.value.compareTo(a.value));
          return matched.first.key;
        }
      } catch (_) {}
    }

    // (2) معرف جهاز DEVICE-… ⇒ بحث متعدد الطبقات + ربط تلقائي:
    if (RegExp(r'^DEVICE-', caseSensitive: false).hasMatch(id)) {
      final devId = id.toUpperCase();

      // (أ-0) فهرس device_index أولاً في بيئة الإنتاج لأنه يشير دائماً إلى المنشأة النشطة حالياً على الجهاز
      if (clientOverride == null) {
        try {
          final directIdx = await _get(
              'workspaces/_registry/device_index/${Uri.encodeComponent(devId)}');
          if (directIdx is Map) {
            final ws =
                asStr(directIdx['workspace_id'] ?? directIdx['workspaceId']);
            if (ws.isNotEmpty) return ws;
          }
        } catch (_) {}
      }

      // (أ) فهرس التجارب — أرخص مسح، ويجمع مرشحي الربط التلقائي.
      final trials = await _get('trials');
      final unlabeled = <String>{}; // مساحات بلا device_id في فهرسها.
      if (trials is Map) {
        String bestWs = '';
        int bestScore = -1;
        for (final e in trials.entries) {
          final v = e.value;
          if (v is! Map) continue;
          final ws = asStr(v['workspace_id'] ?? v['workspaceId']);
          final entryDev = asStr(v['device_id'] ?? v['deviceId']).toUpperCase();
          if ((entryDev == devId || '${e.key}'.toUpperCase() == devId) &&
              ws.isNotEmpty) {
            final ts = asMs(v['requested_at'] ?? v['updated_at'] ?? v['created_at']);
            final isUnactivated = asStr(v['status']) == 'unactivated' ? 1 : 0;
            final score = ts + (isUnactivated * 1000000000000);
            if (bestWs.isEmpty || score >= bestScore) {
              bestWs = ws;
              bestScore = score;
            }
          }
          if (ws.isNotEmpty && entryDev.isEmpty) {
            unlabeled.add(ws);
          }
        }
        if (bestWs.isNotEmpty) return bestWs;
      }

      // (ب) مسح المساحات — طلب واحد لمفاتيح المساحات ثم مسح متوازٍ بسقف [kMaxWorkspaceScan].
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

      // (ج) الربط التلقائي
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

    // (3) معرف مساحة مباشر — نتحقق من وجود عقدة الاشتراك أو المساحة أو سجل التجربة.
    final sub = await _get('workspaces/${Uri.encodeComponent(id)}/subscription');
    if (sub != null) return id;
    final ws =
        await _get('workspaces/${Uri.encodeComponent(id)}', {'shallow': 'true'});
    if (ws != null) return id;

    // بحث في /trials عن مساحة تحمل نفس المعرف
    try {
      final trials = await _get('trials');
      if (trials is Map) {
        for (final e in trials.entries) {
          final v = e.value;
          if (v is! Map) continue;
          final tWs = asStr(v['workspace_id'] ?? v['workspaceId']);
          if (tWs.toLowerCase() == id.toLowerCase() && tWs.isNotEmpty) {
            return tWs;
          }
        }
      }
    } catch (_) {}

    // إذا أدخل العميل أو المشرف الكود المختصر بدون بادئة DEVICE- (مثل FFNQXRJ3KDL9)
    if (clientOverride == null &&
        RegExp(r'^[A-Z0-9]{6,24}$', caseSensitive: false).hasMatch(id) &&
        !id.toLowerCase().startsWith('ws_') &&
        !id.toLowerCase().startsWith('ws-')) {
      try {
        return await resolveWorkspaceId('DEVICE-${id.toUpperCase()}');
      } catch (_) {}
    }

    // في بيئة الإنتاج: إذا أدخل المشرف معرف مساحة عمل يبدأ بـ ws_ أو WS- لم يُرفع بعد، نقبله فوراً
    if (clientOverride == null &&
        (id.startsWith('ws_') || id.toUpperCase().startsWith('WS-'))) {
      return id;
    }

    throw Exception('لا توجد مساحة عمل بهذا المعرف في قاعدة البيانات.');
  }

  /// استعلام ذكي فوري عن المنشأة عبر (device_id أو ws_id أو رقم الهاتف) من /trials و /workspaces.
  Future<WorkspaceLookupPreview> lookupWorkspacePreview(String rawQuery) async {
    final trimmed = rawQuery.trim();
    if (trimmed.isEmpty) {
      throw Exception('أدخل كود الجهاز أو معرف المساحة أو رقم الهاتف للبحث');
    }

    String ws = '';
    try {
      ws = await resolveWorkspaceId(trimmed);
    } catch (_) {
      if (RegExp(r'^DEVICE-', caseSensitive: false).hasMatch(trimmed)) {
        final cleanDev =
            trimmed.toUpperCase().replaceAll(RegExp(r'[.#$\[\]/]'), '_');
        ws = 'ws_$cleanDev';
      } else if (trimmed.startsWith('ws_') ||
          trimmed.toUpperCase().startsWith('WS-')) {
        ws = trimmed;
      } else {
        rethrow;
      }
    }

    final enc = Uri.encodeComponent(ws);
    Map? sub;
    Map? trialEntry;
    String trialFp = '';

    try {
      final s = await _get('workspaces/$enc/subscription');
      if (s is Map) sub = s;
    } catch (_) {}

    try {
      final trials = await _get('trials');
      if (trials is Map) {
        final normPhone = normalizeSubscriberPhone(trimmed);
        for (final e in trials.entries) {
          final v = e.value;
          if (v is! Map) continue;
          final vWs = asStr(v['workspace_id'] ?? v['workspaceId']);
          final vDev = asStr(v['device_id'] ?? v['deviceId']);
          final vPhone = normalizeSubscriberPhone(
              asStr(v['phone'] ?? v['phone_number'] ?? v['whatsapp']));
          if (vWs == ws ||
              (vDev.isNotEmpty &&
                  vDev.toUpperCase() == trimmed.toUpperCase()) ||
              ('${e.key}'.toLowerCase() == trimmed.toLowerCase()) ||
              (normPhone.isNotEmpty && vPhone == normPhone)) {
            trialEntry = v;
            trialFp = '${e.key}';
            break;
          }
        }
      }
    } catch (_) {}

    final rosterList = await getConnectedDevices(ws);

    String storeName = asStr(sub?['storeName'] ??
        sub?['store_name'] ??
        sub?['businessName'] ??
        trialEntry?['storeName'] ??
        trialEntry?['store_name'] ??
        trialEntry?['businessName']);
    String ownerName = asStr(sub?['clientName'] ??
        sub?['client_name'] ??
        sub?['owner_name'] ??
        sub?['userName'] ??
        trialEntry?['clientName'] ??
        trialEntry?['client_name'] ??
        trialEntry?['owner_name'] ??
        trialEntry?['userName']);
    String phone = asStr(sub?['phone'] ??
        sub?['phone_number'] ??
        sub?['whatsapp'] ??
        trialEntry?['phone'] ??
        trialEntry?['phone_number'] ??
        trialEntry?['whatsapp']);
    String devId = asStr(sub?['deviceId'] ??
        sub?['device_id'] ??
        sub?['deviceRef'] ??
        sub?['device_ref'] ??
        trialEntry?['device_id'] ??
        trialEntry?['deviceId']);

    if (storeName.isEmpty || ownerName.isEmpty || phone.isEmpty || devId.isEmpty) {
      try {
        final req = await _get('workspaces/$enc/license_request');
        if (req is Map) {
          if (storeName.isEmpty) {
            storeName = asStr(req['storeName'] ?? req['store_name']);
          }
          if (ownerName.isEmpty) {
            ownerName = asStr(req['clientName'] ?? req['client_name']);
          }
          if (phone.isEmpty) phone = asStr(req['phone']);
          if (devId.isEmpty) {
            devId = asStr(req['deviceId'] ?? req['device_id']);
          }
        }
      } catch (_) {}
    }

    if (devId.isEmpty && rosterList.isNotEmpty) {
      devId = rosterList.first.deviceId;
    }
    if (devId.isEmpty &&
        RegExp(r'^DEVICE-', caseSensitive: false).hasMatch(trimmed)) {
      devId = trimmed.toUpperCase();
    }

    final fp = asStr(sub?['device_fingerprint'] ?? trialFp);
    final activeCount = rosterList.isNotEmpty
        ? rosterList.length
        : asInt(sub?['active_devices'] ?? trialEntry?['active_devices'], 1);
    final maxDevs =
        asInt(sub?['max_devices'] ?? trialEntry?['max_devices'], 1);
    final status =
        asStr(sub?['status'] ?? trialEntry?['status'] ?? 'trial');
    final planType = asStr(sub?['plan_type'] ??
        sub?['planType'] ??
        trialEntry?['plan_type'] ??
        (maxDevs > 1 ? 'enterprise' : 'individual'));
    final expiresAt = asMs(sub?['expires_at'] ??
        sub?['expiryDate'] ??
        trialEntry?['expires_at'] ??
        trialEntry?['expiryDate']);

    return WorkspaceLookupPreview(
      workspaceId: ws,
      storeName: storeName,
      ownerName: ownerName,
      phone: phone,
      deviceId: devId,
      fingerprint: fp,
      activeDevices: activeCount < 1 ? 1 : activeCount,
      maxDevices: maxDevs < 1 ? 1 : maxDevs,
      planType: planType,
      status: status.isEmpty ? 'trial' : status,
      expiresAtMs: expiresAt,
      rosterDevices: rosterList,
      foundInCloud: sub != null || trialEntry != null || rosterList.isNotEmpty,
    );
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
    int? customExpiresAtMs,
    String? statusOverride,
    bool respectMaxDevices = false,
  }) async {
    final int seats;
    final String plan;
    if (respectMaxDevices) {
      seats = maxDevices < 1 ? 1 : maxDevices;
      plan = (planType == 'enterprise' || seats > 1)
          ? 'enterprise'
          : 'individual';
    } else {
      plan = planType == 'enterprise' ? 'enterprise' : 'individual';
      seats = plan == 'enterprise' ? (maxDevices < 2 ? 2 : maxDevices) : 1;
    }
    final effectiveStatus = (statusOverride != null && statusOverride.trim().isNotEmpty)
        ? statusOverride.trim()
        : (duration == PlanDuration.trial ? 'trial' : 'active');

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
    final expires = (customExpiresAtMs != null && customExpiresAtMs > 0)
        ? customExpiresAtMs
        : (base + duration.span.inMilliseconds);

    final subPayload = <String, dynamic>{
      'status': effectiveStatus,
      'is_active': effectiveStatus == 'active',
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
      final trialPatch = <String, dynamic>{
        'status': effectiveStatus,
        'expires_at': expires,
        'workspace_id': ws,
        'plan_type': plan,
        'max_devices': seats,
        'updated_at': now,
        if (clientName.trim().isNotEmpty) 'client_name': clientName.trim(),
        if (storeName.trim().isNotEmpty) 'store_name': storeName.trim(),
        if (phone.trim().isNotEmpty) 'phone': phone.trim(),
      };
      if (fp.isNotEmpty) {
        final existingTrial = await _get('trials/${Uri.encodeComponent(fp)}');
        final existingTrialWs = existingTrial is Map
            ? asStr(existingTrial['workspace_id'] ?? existingTrial['workspaceId'])
            : '';
        final existingTrialActive =
            existingTrial is Map && asStr(existingTrial['status']) == 'active';
        if (existingTrialActive &&
            existingTrialWs.isNotEmpty &&
            existingTrialWs != ws) {
          await _patch(
              'trials/${Uri.encodeComponent('${fp}_$ws')}', trialPatch);
        } else {
          await _patch('trials/${Uri.encodeComponent(fp)}', trialPatch);
        }
      } else {
        final trials = await _get('trials');
        var patchedAny = false;
        if (trials is Map) {
          for (final e in trials.entries) {
            final v = e.value;
            if (v is Map && asStr(v['workspace_id'] ?? v['workspaceId']) == ws) {
              await _patch(
                  'trials/${Uri.encodeComponent('${e.key}')}', trialPatch);
              patchedAny = true;
            }
          }
        }
        if (!patchedAny && clientOverride == null) {
          await _patch('trials/${Uri.encodeComponent(ws)}', trialPatch);
        }
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

  /// التحقق مما إذا كان سجل الجهاز في السحابة محذوفاً أو مطروداً أو معزولاً.
  static bool _isDeviceMapRevoked(Map r) {
    if (asInt(r['revoked']) == 1 || r['revoked'] == true) return true;
    if (asStr(r['revoked_at']).isNotEmpty || asStr(r['expelled_at']).isNotEmpty) {
      return true;
    }
    if (r.containsKey('is_paired') &&
        r['is_paired'] != true &&
        asInt(r['is_paired'], 1) == 0) {
      return true;
    }
    return false;
  }

  Future<List<SubscriberEntry>> recentSubscribers({
    int limit = 100,
    bool includeAbandoned = false,
  }) async {
    dynamic rootData;
    if (includeAbandoned) {
      try {
        rootData = await _get('workspaces');
      } catch (_) {
        rootData = await _get('workspaces', {'shallow': 'true'});
      }
    } else {
      rootData = await _get('workspaces', {'shallow': 'true'});
    }
    if (rootData is! Map || rootData.isEmpty) return const [];
    final wsKeys = rootData.keys
        .map((k) => '$k')
        .where((k) =>
            !k.startsWith('_') && (clientOverride != null || k != 'default'))
        .take(kMaxSubscriberScan)
        .toList();

    final rows = await _gather<List<SubscriberEntry>>(
      [
        for (final ws in wsKeys)
          () => _readWorkspaceEntries(
                ws,
                preloadedNode:
                    rootData[ws] is Map ? rootData[ws] as Map : null,
                includeAbandoned: includeAbandoned,
              )
      ],
    );
    final raw = rows.expand((r) => r).toList();

    // استبعاد أي عقدة فرعية لجهاز عضو مسجل ضمن roster منشأة أخرى (Workspace-Level Licensing)
    // إلا في حال طلب إظهار المساحات المهجورة لتنظيفها.
    final memberDeviceIdsInRosters = <String>{};
    if (!includeAbandoned) {
      for (final entry in raw) {
        for (final d in entry.rosterDevices) {
          final devKey = d.deviceId.trim().toUpperCase();
          if (devKey.isEmpty) continue;
          if (!d.isOwner || entry.rosterDevices.length > 1) {
            final derivedWs =
                'ws_${devKey.replaceAll(RegExp(r'[.#$\[\]/]'), '_')}';
            if (entry.workspaceId.toUpperCase() != derivedWs.toUpperCase() &&
                entry.workspaceId.toUpperCase() != devKey) {
              memberDeviceIdsInRosters.add(devKey);
            }
          }
        }
      }
    }

    final orgOnly = raw.where((entry) {
      if (includeAbandoned) return true;
      final dev = entry.deviceId.trim().toUpperCase();
      final wsUpper = entry.workspaceId.trim().toUpperCase();
      if (dev.isNotEmpty &&
          memberDeviceIdsInRosters.contains(dev) &&
          (wsUpper == 'WS_$dev' || wsUpper == dev)) {
        return false;
      }
      return true;
    }).toList();

    // ترتيب: الحسابات الفعالة أولاً، ثم الأطول مدة والأحدث نشاطاً
    orgOnly.sort((a, b) {
      final aActive = a.status == 'active' ? 1 : 0;
      final bActive = b.status == 'active' ? 1 : 0;
      final cmp = bActive.compareTo(aActive);
      if (cmp != 0) return cmp;
      final expCmp = b.expiresAtMs.compareTo(a.expiresAtMs);
      if (expCmp != 0) return expCmp;
      return b.activatedAtMs.compareTo(a.activatedAtMs);
    });

    // تجميع ودمج سجلات المشتركين:
    // كل منشأة مستقلة (WS-...) تبقى في سطر مستقل بمعرفها (workspaceId) حتى لو كان لنفس المالك
    // عدة منشآت بنفس رقم الهاتف أو نفس الجهاز، ولا تُدمج إلا السجلات المكررة لنفس المنشأة أو
    // العقدة الافتراضية المشتقة من معرف الجهاز (ws_DEVICE-...).
    final out = <SubscriberEntry>[];
    final indexByKey = <String, int>{};

    bool isExplicitMultiWorkspace(String wsId) =>
        wsId.trim().toUpperCase().startsWith('WS-');

    for (final entry in orgOnly) {
      final wsTrim = entry.workspaceId.trim();
      final wsKey = 'ws:${wsTrim.toLowerCase()}';
      final isExplicitWs = isExplicitMultiWorkspace(wsTrim);
      final normPhone = normalizeSubscriberPhone(entry.phone);
      final phoneKey =
          (!isExplicitWs && normPhone.isNotEmpty) ? 'phone:$normPhone' : '';
      final dev = entry.deviceId.trim().toUpperCase();
      final devKey = (!isExplicitWs &&
              !includeAbandoned &&
              dev.isNotEmpty &&
              dev.startsWith('DEVICE-'))
          ? 'dev:$dev'
          : '';

      int? existingIdx = indexByKey[wsKey];
      if (existingIdx == null &&
          phoneKey.isNotEmpty &&
          (!includeAbandoned || entry.hasSubscriptionNode)) {
        existingIdx = indexByKey[phoneKey];
      }
      if (existingIdx == null && devKey.isNotEmpty) {
        existingIdx = indexByKey[devKey];
      }

      if (existingIdx != null) {
        final merged = out[existingIdx].mergeWith(entry);
        out[existingIdx] = merged;
        indexByKey[wsKey] = existingIdx;
        if (phoneKey.isNotEmpty) indexByKey[phoneKey] = existingIdx;
        if (devKey.isNotEmpty) indexByKey[devKey] = existingIdx;
      } else {
        final newIdx = out.length;
        out.add(entry);
        indexByKey[wsKey] = newIdx;
        if (phoneKey.isNotEmpty) indexByKey[phoneKey] = newIdx;
        if (devKey.isNotEmpty) indexByKey[devKey] = newIdx;
      }
    }

    return out.take(limit).toList();
  }

  Future<List<SubscriberEntry>> _readWorkspaceEntries(
    String ws, {
    Map? preloadedNode,
    bool includeAbandoned = false,
  }) async {
    final enc = Uri.encodeComponent(ws);
    Map? live;
    if (preloadedNode != null && preloadedNode['subscription'] is Map) {
      live = preloadedNode['subscription'] as Map;
    } else {
      try {
        final sub = await _get('workspaces/$enc/subscription');
        if (sub is Map) live = sub;
      } catch (_) {}
    }

    // حصر القائمة على المنشآت فقط عند عدم طلب المساحات المهجورة
    if (!includeAbandoned && live != null) {
      final role = asStr(
              live['role'] ?? live['workspace_mode'] ?? live['device_role'])
          .toLowerCase();
      if (role == 'member' || live['is_member'] == true) {
        return const [];
      }
    }

    // قراءة قائمة الأجهزة المطرودة/المحذوفة لمنع إعادة إظهارها
    final revokedIds = <String>{};
    try {
      final revNode = preloadedNode != null
          ? preloadedNode['revoked_devices']
          : (clientOverride == null
              ? await _get('workspaces/$enc/revoked_devices')
              : null);
      if (revNode is Map) {
        for (final k in revNode.keys) {
          final clean = '$k'.trim().toUpperCase();
          if (clean.isNotEmpty) revokedIds.add(clean);
        }
      }
    } catch (_) {}

    // قراءة أجهزة المنشأة (Roster & Devices) مع منع التكرار بالـ ID أو بالبريد الإلكتروني أو بالبصمة
    final rosterById = <String, ConnectedDevice>{};
    final keyByFp = <String, String>{};
    final keyByEmail = <String, String>{};
    var hadCloudDeviceNodes = false;

    void addOrMergeDevice(String rawId, Map data) {
      if (_isDeviceMapRevoked(data)) return;
      final d = ConnectedDevice.fromJson(rawId, data);
      final k = d.deviceId.trim().toUpperCase();
      if (k.isEmpty || revokedIds.contains(k)) return;
      final fp = d.fingerprint.trim().toLowerCase();
      final em = d.email.trim().toLowerCase();
      if (em.isNotEmpty && keyByEmail.containsKey(em)) {
        final prevKey = keyByEmail[em]!;
        final prev = rosterById[prevKey];
        if (prev == null || d.lastSeenAt >= prev.lastSeenAt) {
          rosterById.remove(prevKey);
          rosterById[k] = d;
          keyByEmail[em] = k;
          if (fp.isNotEmpty) keyByFp[fp] = k;
        }
        return;
      }
      if (fp.isNotEmpty && keyByFp.containsKey(fp)) {
        final prevKey = keyByFp[fp]!;
        final prev = rosterById[prevKey];
        if (prev == null || d.lastSeenAt >= prev.lastSeenAt) {
          rosterById.remove(prevKey);
          rosterById[k] = d;
          keyByFp[fp] = k;
          if (em.isNotEmpty) keyByEmail[em] = k;
        }
        return;
      }
      final prev = rosterById[k];
      if (prev == null || d.lastSeenAt >= prev.lastSeenAt) {
        rosterById[k] = d;
        if (fp.isNotEmpty) keyByFp[fp] = k;
        if (em.isNotEmpty) keyByEmail[em] = k;
      }
    }

    try {
      final roster = (preloadedNode != null && preloadedNode.containsKey('roster'))
          ? preloadedNode['roster']
          : await _get('workspaces/$enc/roster');
      if (roster is Map) {
        hadCloudDeviceNodes = true;
        for (final e in roster.entries) {
          final id = '${e.key}'.trim();
          if (id.isEmpty || e.value is! Map) continue;
          addOrMergeDevice(id, e.value as Map);
        }
      }
    } catch (_) {}

    String storeFallback = asStr(live?['storeName'] ??
        live?['store_name'] ??
        live?['businessName']);
    String clientFallback = asStr(live?['clientName'] ??
        live?['client_name'] ??
        live?['owner_name'] ??
        live?['userName']);
    String phoneFallback = asStr(live?['phone'] ??
        live?['phone_number'] ??
        live?['whatsapp']);
    String devIdFallback = asStr(live?['deviceId'] ??
        live?['device_id'] ??
        live?['deviceRef'] ??
        live?['device_ref']);

    if (preloadedNode != null ||
        clientOverride == null ||
        storeFallback.isEmpty ||
        clientFallback.isEmpty ||
        phoneFallback.isEmpty ||
        devIdFallback.isEmpty ||
        rosterById.isEmpty) {
      try {
        final devs = (preloadedNode != null && preloadedNode.containsKey('devices'))
            ? preloadedNode['devices']
            : (clientOverride == null
                ? await _get('workspaces/$enc/devices')
                : null);
        if (devs is Map) {
          hadCloudDeviceNodes = true;
          for (final e in devs.entries) {
            final id = '${e.key}'.trim();
            final dv = e.value;
            if (dv is Map) {
              if (id.isNotEmpty) {
                addOrMergeDevice(id, dv);
              }
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
                devIdFallback = asStr(dv['deviceId'] ?? dv['device_id'] ?? id);
              }
            }
          }
        }
      } catch (_) {}
    }

    if (preloadedNode != null && preloadedNode['meta'] is Map) {
      final meta = preloadedNode['meta'] as Map;
      if (storeFallback.isEmpty) {
        storeFallback = asStr(
            meta['storeName'] ?? meta['store_name'] ?? meta['businessName']);
      }
      if (clientFallback.isEmpty) {
        clientFallback = asStr(
            meta['owner_name'] ?? meta['clientName'] ?? meta['client_name']);
      }
      if (phoneFallback.isEmpty) {
        phoneFallback = asStr(meta['phone'] ?? meta['whatsapp']);
      }
    }

    if (clientOverride == null &&
        (storeFallback.isEmpty ||
            clientFallback.isEmpty ||
            phoneFallback.isEmpty ||
            devIdFallback.isEmpty)) {
      try {
        final req = (preloadedNode != null &&
                preloadedNode.containsKey('license_request'))
            ? preloadedNode['license_request']
            : await _get('workspaces/$enc/license_request');
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

    // قراءة السجل الإداري كمرجع تكميلي وتجميعه في كيان منشأة واحد فقط (بدون تكرار بطاقات أو اختلاق أجهزة محذوفة)
    Map? latestLog;
    int latestLogActivatedAt = 0;
    try {
      final logs = (preloadedNode != null && preloadedNode.containsKey('admin_log'))
          ? preloadedNode['admin_log']
          : await _get('workspaces/$enc/admin_log');
      if (logs is Map) {
        for (final e in logs.entries) {
          final v = e.value;
          if (v is! Map) continue;
          final actAt = asMs(v['activated_at']) > 0
              ? asMs(v['activated_at'])
              : asMs(e.key);
          if (latestLog == null || actAt >= latestLogActivatedAt) {
            latestLog = v;
            latestLogActivatedAt = actAt;
          }
        }
      }
    } catch (_) {}

    if (live == null && latestLog == null && !includeAbandoned) {
      return const [];
    }

    final devRef = asStr(live?['device_id'] ??
        live?['deviceId'] ??
        live?['device_ref'] ??
        live?['deviceRef'] ??
        latestLog?['device_ref'] ??
        devIdFallback);
    final explicitCount = live != null &&
            (live.containsKey('activeDevicesCount') ||
                live.containsKey('active_devices') ||
                live.containsKey('activeDevices'))
        ? asInt(
            live['activeDevicesCount'] ??
                live['active_devices'] ??
                live['activeDevices'],
            -1)
        : -1;

    if (rosterById.isEmpty &&
        !hadCloudDeviceNodes &&
        explicitCount != 0 &&
        devRef.isNotEmpty &&
        !revokedIds.contains(devRef.toUpperCase())) {
      rosterById[devRef.toUpperCase()] = ConnectedDevice(
        deviceId: devRef,
        deviceName: devRef,
        model: 'جهاز المالك',
        platform: 'Android',
        lastSeenAt: asMs(live?['last_seen_at'] ??
            live?['updated_at'] ??
            live?['activated_at'] ??
            latestLogActivatedAt),
        isOwner: true,
      );
    }

    final rosterList = rosterById.values.toList()
      ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));

    var maxLastSeen = asMs(live?['last_seen_at'] ??
        live?['lastSeenAt'] ??
        live?['updated_at'] ??
        live?['activated_at'] ??
        latestLogActivatedAt);
    for (final d in rosterList) {
      if (d.lastSeenAt > maxLastSeen) maxLastSeen = d.lastSeenAt;
    }

    final resolvedStore = asStr(live?['storeName'] ??
        live?['store_name'] ??
        latestLog?['store_name'] ??
        latestLog?['storeName'] ??
        storeFallback);
    final resolvedClient = asStr(live?['clientName'] ??
        live?['client_name'] ??
        live?['owner_name'] ??
        latestLog?['client_name'] ??
        latestLog?['clientName'] ??
        clientFallback);
    final resolvedPhone = asStr(live?['phone'] ??
        live?['phone_number'] ??
        latestLog?['phone'] ??
        latestLog?['phone_number'] ??
        phoneFallback);

    final rawKey = asStr(live?['licenseKey'] ??
        live?['license_key'] ??
        latestLog?['license_key'] ??
        latestLog?['licenseKey']);
    final resolvedKey = rawKey.isNotEmpty
        ? rawKey
        : generateLicenseKey(devRef.isNotEmpty ? devRef : ws);

    final hasSub = live != null || latestLog != null;
    final activeCount = rosterList.isNotEmpty
        ? rosterList.length
        : (explicitCount >= 0 ? explicitCount : (hasSub ? 1 : 0));

    return [
      SubscriberEntry(
        workspaceId: ws,
        planType: _pick(live?['plan_type'], latestLog?['plan_type'], 'individual'),
        status: hasSub ? _pick(live?['status'], null, 'active') : 'abandoned',
        maxDevices: asInt(
            _firstNum(live?['max_devices'], latestLog?['max_devices']), 1),
        activeDevices: activeCount < 0 ? 0 : activeCount,
        expiresAtMs: asMs(
            _firstNum(live?['expires_at'], latestLog?['expires_at'])),
        activatedAtMs: asMs(live?['activated_at']) > 0
            ? asMs(live?['activated_at'])
            : latestLogActivatedAt,
        lastSeenAtMs: maxLastSeen,
        deviceRef: devRef,
        clientName: resolvedClient,
        storeName: resolvedStore,
        phone: resolvedPhone,
        deviceId: devRef,
        licenseKey: resolvedKey,
        isFrozen: live?['is_frozen'] == true || live?['frozen'] == true,
        featureFlags: (live?['features'] is Map)
            ? (live!['features'] as Map)
                .map((k, val) => MapEntry('$k', val == true))
            : const {},
        rosterDevices: rosterList,
        hasSubscriptionNode: hasSub,
      ),
    ];
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

  /// 4. الأجهزة المتصلة وطرد/حذف جهاز جذرياً (Multi-Device Management — Roster & Devices)
  Future<List<ConnectedDevice>> getConnectedDevices(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final byId = <String, ConnectedDevice>{};
    final keyByFp = <String, String>{};
    final keyByEmail = <String, String>{};
    final revokedIds = <String>{};

    try {
      final rev = await _get('workspaces/$enc/revoked_devices');
      if (rev is Map) {
        for (final k in rev.keys) {
          final clean = '$k'.trim().toUpperCase();
          if (clean.isNotEmpty) revokedIds.add(clean);
        }
      }
    } catch (_) {}

    void addOrMerge(String rawId, Map data) {
      if (_isDeviceMapRevoked(data)) return;
      final d = ConnectedDevice.fromJson(rawId, data);
      final k = d.deviceId.trim().toUpperCase();
      if (k.isEmpty || revokedIds.contains(k)) return;
      final fp = d.fingerprint.trim().toLowerCase();
      final em = d.email.trim().toLowerCase();
      if (em.isNotEmpty && keyByEmail.containsKey(em)) {
        final prevKey = keyByEmail[em]!;
        final prev = byId[prevKey];
        if (prev == null || d.lastSeenAt >= prev.lastSeenAt) {
          byId.remove(prevKey);
          byId[k] = d;
          keyByEmail[em] = k;
          if (fp.isNotEmpty) keyByFp[fp] = k;
        }
        return;
      }
      if (fp.isNotEmpty && keyByFp.containsKey(fp)) {
        final prevKey = keyByFp[fp]!;
        final prev = byId[prevKey];
        if (prev == null || d.lastSeenAt >= prev.lastSeenAt) {
          byId.remove(prevKey);
          byId[k] = d;
          keyByFp[fp] = k;
          if (em.isNotEmpty) keyByEmail[em] = k;
        }
        return;
      }
      final prev = byId[k];
      if (prev == null || d.lastSeenAt >= prev.lastSeenAt) {
        byId[k] = d;
        if (fp.isNotEmpty) keyByFp[fp] = k;
        if (em.isNotEmpty) keyByEmail[em] = k;
      }
    }

    try {
      final res = await _get('workspaces/$enc/devices');
      if (res is Map) {
        for (final e in res.entries) {
          if (e.value is Map) {
            addOrMerge('${e.key}', e.value as Map);
          }
        }
      }
    } catch (_) {}
    try {
      final roster = await _get('workspaces/$enc/roster');
      if (roster is Map) {
        for (final e in roster.entries) {
          final id = '${e.key}'.trim();
          if (id.isEmpty || e.value is! Map) continue;
          addOrMerge(id, e.value as Map);
        }
      }
    } catch (_) {}
    final list = byId.values.toList()
      ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return list;
  }

  /// حذف جهاز جذرياً من المنشأة ومن الروستر ومن السجل العام مع التحقق الصارم من كود 200 OK
  /// وتحديث عداد الأجهزة في مساحة العمل (activeDevicesCount / active_devices).
  Future<int> kickDevice(
    String wsId,
    String deviceId, {
    int? currentActiveCount,
  }) async {
    final cleanWs = wsId.trim();
    final cleanDev = deviceId.trim();
    if (cleanWs.isEmpty || cleanDev.isEmpty) {
      throw Exception('معرف المنشأة أو الجهاز فارغ — تعذر الحذف.');
    }
    final enc = Uri.encodeComponent(cleanWs);
    final devEnc = Uri.encodeComponent(cleanDev);

    // 1. حذف الجهاز من مسار المنشأة (يتحقق بصرامة من كود 200 OK)
    await _deleteStrict200('workspaces/$enc/devices/$devEnc');

    // 2. حذف الجهاز من قائمة الأعضاء/الروستر (يتحقق بصرامة من كود 200 OK)
    await _deleteStrict200('workspaces/$enc/roster/$devEnc');

    // 3. حذف سجل الجهاز العام إن وجد (يتحقق بصرامة من كود 200 OK مع دعم مسار الفهرس عند تقييد الجذر)
    await _deleteStrict200('devices/$devEnc', allowRegistryFallback: true);

    // تنظيف أي مفاتيح مطابقة لحالة أحرف مختلفة أو فهرس الجهاز
    try {
      final devIdxKey = cleanDev.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
      await _delete(
          'workspaces/_registry/device_index/${Uri.encodeComponent(devIdxKey)}');
    } catch (_) {}

    try {
      await _put('workspaces/$enc/revoked_devices/$devEnc', {
        'deviceId': cleanDev,
        'kicked_at': DateTime.now().millisecondsSinceEpoch,
      });
      await _put('workspaces/$enc/evictions/$devEnc', {
        'deviceId': cleanDev,
        'expelled_at': DateTime.now().millisecondsSinceEpoch,
        'reason': 'deleted_by_admin',
      });
    } catch (_) {}

    // 4. تحديث عداد الأجهزة في مساحة العمل (activeDevicesCount / active_devices)
    int newCount = 0;
    try {
      final remaining = await getConnectedDevices(cleanWs);
      final filtered = remaining
          .where((d) => d.deviceId.trim().toUpperCase() != cleanDev.toUpperCase())
          .toList();
      if (currentActiveCount != null && currentActiveCount > 0) {
        final dec = currentActiveCount - 1;
        newCount = filtered.isNotEmpty && filtered.length < dec
            ? filtered.length
            : (dec < 0 ? 0 : dec);
      } else {
        newCount = filtered.length;
      }
    } catch (_) {
      newCount = currentActiveCount != null && currentActiveCount > 0
          ? currentActiveCount - 1
          : 0;
    }

    final subPatch = <String, dynamic>{
      'active_devices': newCount,
      'activeDevices': newCount,
      'activeDevicesCount': newCount,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    try {
      final curSub = await _get('workspaces/$enc/subscription');
      if (curSub is Map) {
        final subDev =
            asStr(curSub['device_id'] ?? curSub['deviceId'] ?? curSub['device_ref']);
        if (subDev.toUpperCase() == cleanDev.toUpperCase()) {
          subPatch['device_id'] = '';
          subPatch['deviceId'] = '';
          subPatch['device_ref'] = '';
        }
      }
    } catch (_) {}
    await _patch('workspaces/$enc/subscription', subPatch);

    return newCount;
  }

  Future<int> deleteDeviceFromWorkspace(
    String wsId,
    String deviceId, {
    int? currentActiveCount,
  }) =>
      kickDevice(wsId, deviceId, currentActiveCount: currentActiveCount);

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

  /// حذف مساحة العمل بالكامل ونهائياً من السحابة (Purge Workspace) دون ترك أي مخلفات سحابية،
  /// مع التحقق الصارم من كود الاستجابة 200 OK وتنظيف كافة الفهارس والروابط المرتبطة.
  Future<void> purgeWorkspace(String wsId) async {
    final cleanWs = wsId.trim();
    if (cleanWs.isEmpty || cleanWs == 'default' || cleanWs.startsWith('_')) {
      throw Exception('معرف مساحة العمل غير صالح للحذف النهائي: $cleanWs');
    }
    final enc = Uri.encodeComponent(cleanWs);

    // قراءة البريد والهاتف قبل الحذف لتنظيف فهارس البريد والهاتف وuser_workspaces
    String ownerEmail = '';
    String ownerPhone = '';
    try {
      final subNode = await _get('workspaces/_registry/subscriptions_index/$enc');
      if (subNode is Map) {
        ownerEmail = '${subNode['owner_email'] ?? subNode['ownerEmail'] ?? subNode['email'] ?? ''}'.trim().toLowerCase();
        ownerPhone = '${subNode['phone'] ?? subNode['owner_phone'] ?? subNode['whatsapp'] ?? ''}'.trim();
      }
      if (ownerEmail.isEmpty || ownerPhone.isEmpty) {
        final metaNode = await _get('workspaces/$enc/meta');
        if (metaNode is Map) {
          if (ownerEmail.isEmpty) {
            ownerEmail = '${metaNode['owner_email'] ?? metaNode['ownerEmail'] ?? metaNode['email'] ?? ''}'.trim().toLowerCase();
          }
          if (ownerPhone.isEmpty) {
            ownerPhone = '${metaNode['phone'] ?? metaNode['owner_phone'] ?? metaNode['whatsapp'] ?? ''}'.trim();
          }
        }
      }
    } catch (_) {}

    // حذف العقدة الجذرية للمساحة بالكامل من /workspaces/{workspaceId} مع التحقق الصارم 200 OK
    await _deleteStrict200('workspaces/$enc');
    // تنظيف الفهارس المرتبطة لمنع أي مخلفات سحابية
    try {
      await _delete('workspaces/_registry/subscriptions_index/$enc');
    } catch (_) {}
    try {
      await _delete('workspaces/_registry/license_hub/licenses/$enc');
    } catch (_) {}
    try {
      await _delete('support_chats/$enc');
    } catch (_) {}
    try {
      final invIdx = await _get('workspaces/_registry/invite_index');
      if (invIdx is Map) {
        for (final entry in invIdx.entries) {
          final v = entry.value;
          if (v is Map &&
              ('${v['ws'] ?? v['workspaceId'] ?? ''}'.trim() == cleanWs)) {
            final codeKey = Uri.encodeComponent('${entry.key}');
            await _delete('workspaces/_registry/invite_index/$codeKey');
          }
        }
      }
    } catch (_) {}
    if (ownerEmail.isNotEmpty) {
      final emailKey = ownerEmail.replaceAll('.', ',').replaceAll(RegExp(r'[#\$\[\]/]'), '_');
      try {
        await _delete('workspaces/_registry/user_workspaces/$emailKey/$enc');
      } catch (_) {}
      try {
        await _delete('workspaces/_registry/emails_index/$emailKey');
      } catch (_) {}
    }
    final cleanDigits = ownerPhone.replaceAll(RegExp(r'[^\d]'), '');
    if (cleanDigits.length >= 7) {
      final normPhone = cleanDigits.startsWith('00')
          ? '+${cleanDigits.substring(2)}'
          : '+$cleanDigits';
      final phoneKey = normPhone.replaceAll(RegExp(r'[.#\$\[\]/]'), '_');
      try {
        await _delete('workspaces/_registry/phones_index/$phoneKey');
      } catch (_) {}
    }
  }

  /// حذف دفعة من المنشآت المحددة بشكل متتابع ومتماثل مع مؤشر تقدم.
  Future<int> purgeWorkspacesBatch(
    List<String> wsIds, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final targets = wsIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != 'default' && !e.startsWith('_'))
        .toSet()
        .toList();
    var completed = 0;
    for (final wsId in targets) {
      await purgeWorkspace(wsId);
      completed++;
      onProgress?.call(completed, targets.length);
    }
    return completed;
  }

  /// حذف مشترك وترخيصه ومساحته فوراً وبشكل مباشر ونهائي (بدون سلة محذوفات).
  Future<void> deleteSubscriberImmediately(String wsId) async {
    await purgeWorkspace(wsId);
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
// 🤖 محرك الذكاء الاصطناعي الشامل (Google Gemini API + OpenAI-Compatible Client)
// يدعم: Google Gemini (كافة النماذج المباشرة + التوافقية)، OpenRouter, OpenAI, DeepSeek, Groq, Together, Ollama.
// ============================================================================

/// الرابط الرسمي لواجهة Google Gemini المتوافقة مع OpenAI.
const String kGeminiOpenAiEndpoint =
    'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';

/// الرابط الأساسي لواجهة Google Gemini المباشرة (Native REST API).
const String kGeminiNativeBaseUrl =
    'https://generativelanguage.googleapis.com/v1beta/models';

/// كافة نماذج Google Gemini المتاحة للاختيار المباشر في تطبيق الترخيص.
const List<Map<String, String>> kGeminiAvailableModels = [
  {
    'id': 'gemini-3-flash-preview',
    'label': 'Gemini 3 Flash Preview (الأحدث والأسرع ⚡)',
  },
  {
    'id': 'gemini-3.1-pro-preview',
    'label': 'Gemini 3.1 Pro Preview (الأقوى للمهام المعقدة 🧠)',
  },
  {
    'id': 'gemini-3.1-flash-lite-preview',
    'label': 'Gemini 3.1 Flash Lite Preview (خفيف وفائق السرعة 🚀)',
  },
  {
    'id': 'gemini-2.5-flash',
    'label': 'Gemini 2.5 Flash (متوازن ومستقر ✨)',
  },
  {
    'id': 'gemini-2.5-pro',
    'label': 'Gemini 2.5 Pro (تحليل عميق وموسع 💎)',
  },
  {
    'id': 'gemini-2.5-flash-lite',
    'label': 'Gemini 2.5 Flash Lite (اقتصادي وسريع 💡)',
  },
  {
    'id': 'gemini-2.0-flash',
    'label': 'Gemini 2.0 Flash (الجيل الثاني السريع ⚙️)',
  },
  {
    'id': 'gemini-2.0-flash-lite',
    'label': 'Gemini 2.0 Flash Lite (الجيل الثاني الخفيف 🪶)',
  },
  {
    'id': 'gemini-1.5-pro',
    'label': 'Gemini 1.5 Pro (سياق مليونين رمز 📚)',
  },
  {
    'id': 'gemini-1.5-flash',
    'label': 'Gemini 1.5 Flash (سريع وموثوق ⚡)',
  },
  {
    'id': 'gemini-1.5-flash-8b',
    'label': 'Gemini 1.5 Flash 8B (خفيف جداً 🎯)',
  },
];

/// الرابط الافتراضي لخدمة Chat Completions الشاملة (OpenRouter).
const String kDefaultAiEndpoint =
    'https://openrouter.ai/api/v1/chat/completions';

/// رابط الاستدعاء المباشر لخدمة DeepSeek الرسمية (محفوظ للتوافق).
const String kDeepSeekEndpoint = 'https://api.deepseek.com/chat/completions';

/// النموذج الافتراضي المعتمد في الواجهة الشاملة.
const String kDefaultAiModel = 'deepseek/deepseek-chat';

/// النموذج الافتراضي لـ DeepSeek (محفوظ للتوافق).
const String kDeepSeekDefaultModel = 'deepseek-chat';

/// درجة الحرارة المعتمدة لمحادثة الرفيق الشخصي (`0.7`).
const double kOwnerTemperature = 0.7;

/// الحد الأقصى للرموز المولّدة في كل رد (`2048`).
const int kDeepSeekMaxTokens = 2048;

/// سعة سياق المحادثة الموسعة.
const int kMaxConversationContextMessages = 100;

/// موجه النظام الافتراضي (Persona: الرفيق العفوي متعدد الاهتمامات) — يُحقن كرسالة `system`.
const String kOwnerSystemInstruction = '''
أنت رفيق شخصي تفاعلي، ذكي، وخفيف الظل، ومستمع وفيّ للفضفضة والدردشة مع المدير.
- شخصيتك وطبيعتك: إنسان واسع الاطلاع، سريع البديهة، حاضر الفكاهة، وتجيد خوض الأحاديث في شتى مجالات الحياة (السمر، الفضفضة، التجارة، الثقافة، يوميات العمل، النقاشات العامة، والفلسفة) بنفس الكفاءة التي تفهم بها التقنية.
- أسلوب الحوار:
  1. تكيّف فوراً مع موضوع المستخدم ومزاجه؛ إذا أراد فضفضة عامة أو نقاشاً حراً فتحدث معه كصديق واقعي في جلسة سمر، ولا تجرّ الحديث أبداً نحو البرمجة أو الأكواد ما لم يطلب هو ذلك صراحة.
  2. تحدث بلهجة عربية عفوية وودودة، بلا مقدمات ترحيبية رسمية مكررة ("أهلاً بك كيف أساعدك اليوم") وبلا أسلوب روبوتي.
  3. كن موجزاً ومركزاً وذا لمسة ذكية؛ لا تكتب مقالات طويلة إلا إذا استدعى النقاش ذلك.
''';

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

/// بناء الترويسات القياسية المتوافقة مع كافة مزودي OpenAI و OpenRouter.
Map<String, String> buildOpenAiCompatibleHeaders(String apiKey) =>
    <String, String>{
      'Authorization': 'Bearer ${apiKey.trim()}',
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://nexora.app',
      'X-Title': 'Nexora Admin',
    };

/// بناء الترويسات الرسمية (محفوظ للتوافق).
Map<String, String> buildDeepSeekHeaders(String apiKey) =>
    buildOpenAiCompatibleHeaders(apiKey);

/// رسالة واحدة داخل جلسة الذكاء الاصطناعي (`ChatSession`).
class AiChatMessage {
  final String id;
  final String role; // 'user' | 'assistant' | 'model' | 'system'
  final String text;
  final int timestamp;
  final bool hasError;
  final String? errorText;

  const AiChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
    this.hasError = false,
    this.errorText,
  });

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant' || role == 'model';
  bool get isSystem => role == 'system';

  AiChatMessage copyWith({
    String? id,
    String? role,
    String? text,
    int? timestamp,
    bool? hasError,
    String? errorText,
  }) {
    return AiChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      text: text ?? this.text,
      timestamp: timestamp ?? this.timestamp,
      hasError: hasError ?? this.hasError,
      errorText: errorText,
    );
  }

  Map<String, dynamic> toOpenAiMessage() => <String, dynamic>{
        'role': isUser ? 'user' : 'assistant',
        'content': text,
      };
}

/// جلسة محادثة مستقلة (`ChatSession`) تعمل بمحرك Chat Completions القياسي.
class ChatSession {
  final String personaId;
  String systemInstruction;
  double temperature;
  final int maxTokens;
  final List<AiChatMessage> _history = [];

  ChatSession({
    required this.personaId,
    required this.systemInstruction,
    this.temperature = kOwnerTemperature,
    this.maxTokens = kDeepSeekMaxTokens,
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

  /// إضافة رسالة المستخدم فوراً بشكل متفائل (Optimistic Update) قبل انتظار الـ API.
  void addOptimisticMessage(AiChatMessage msg) {
    final idx = _history.indexWhere((m) => m.id == msg.id);
    if (idx >= 0) {
      _history[idx] = msg;
    } else {
      _history.add(msg);
    }
  }

  /// تحديث حالة الفشل للرسالة داخل السجل دون حذفها نهائياً.
  void updateMessageState(
    String messageId, {
    required bool hasError,
    String? errorText,
  }) {
    final idx = _history.indexWhere((m) => m.id == messageId);
    if (idx >= 0) {
      _history[idx] = _history[idx].copyWith(
        hasError: hasError,
        errorText: errorText,
      );
    }
  }

  /// إرسال رسالة إلى المزود المتوافق مع معيار OpenAI Chat Completions
  /// مع الحفاظ على رسالة المستخدم في السجل عند حدوث خطأ في الشبكة أو المفتاح.
  Stream<String> sendMessageStream(
    String userText, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? existingMessageId,
    http.Client? httpClient,
  }) async* {
    final cleanPrompt = userText.trim();
    if (cleanPrompt.isEmpty) return;

    AiChatMessage userMsg;
    if (existingMessageId != null) {
      final existingIdx =
          _history.indexWhere((m) => m.id == existingMessageId);
      if (existingIdx >= 0) {
        userMsg = _history[existingIdx].copyWith(
          hasError: false,
          errorText: null,
        );
        _history[existingIdx] = userMsg;
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        userMsg = AiChatMessage(
          id: existingMessageId,
          role: 'user',
          text: cleanPrompt,
          timestamp: now,
        );
        _history.add(userMsg);
      }
    } else {
      final now = DateTime.now().millisecondsSinceEpoch;
      userMsg = AiChatMessage(
        id: 'u_$now',
        role: 'user',
        text: cleanPrompt,
        timestamp: now,
      );
      _history.add(userMsg);
    }

    final engine = DualPersonaAiEngine.instance;
    final cleanKey = (apiKey ?? engine.apiKey).trim();
    if (cleanKey.isEmpty) {
      const errMsg =
          'لم يتم إدخال مفتاح الواجهة (API Key) بعد. اضغط على أيقونة الترس (⚙️) في أعلى الشاشة لضبط الإعدادات وإدخال المفتاح.';
      updateMessageState(userMsg.id, hasError: true, errorText: errMsg);
      throw Exception(errMsg);
    }

    final validHistory = _history
        .where((m) => !m.hasError && !m.isSystem || m.id == userMsg.id)
        .toList();
    final recentHistory = validHistory
        .skip(validHistory.length > kMaxConversationContextMessages
            ? validHistory.length - kMaxConversationContextMessages
            : 0)
        .toList();

    final effectiveSystemPrompt = personaId == 'owner_companion'
        ? engine.systemPrompt.trim()
        : systemInstruction.trim();

    final messagesPayload = <Map<String, dynamic>>[
      if (effectiveSystemPrompt.isNotEmpty)
        {
          'role': 'system',
          'content': effectiveSystemPrompt,
        },
      for (final m in recentHistory) m.toOpenAiMessage(),
    ];

    final buffer = StringBuffer();
    try {
      await for (final chunk in engine.streamDeepSeekChat(
        messages: messagesPayload,
        apiKey: cleanKey,
        baseUrl: baseUrl ?? engine.baseUrl,
        model: model ?? engine.modelId,
        temperature: temperature,
        maxTokens: maxTokens,
        httpClient: httpClient,
      )) {
        buffer.write(chunk);
        yield chunk;
      }
    } catch (e) {
      final errText = e.toString().replaceFirst('Exception: ', '');
      updateMessageState(userMsg.id, hasError: true, errorText: errText);
      rethrow;
    }

    final finalReply = buffer.toString().trim();
    if (finalReply.isEmpty) {
      const errText = 'تعذر الحصول على رد من مزود الذكاء الاصطناعي.';
      updateMessageState(userMsg.id, hasError: true, errorText: errText);
      throw Exception(errText);
    }

    updateMessageState(userMsg.id, hasError: false, errorText: null);

    final replyNow = DateTime.now().millisecondsSinceEpoch;
    _history.add(
      AiChatMessage(
        id: 'm_$replyNow',
        role: 'assistant',
        text: finalReply,
        timestamp: replyNow,
      ),
    );
  }

  /// إرسال رسالة والحصول على النص الكامل مباشرةً.
  Future<String> sendMessage(
    String userText, {
    String? apiKey,
    String? baseUrl,
    String? model,
    http.Client? httpClient,
  }) async {
    final buf = StringBuffer();
    await for (final chunk in sendMessageStream(
      userText,
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      httpClient: httpClient,
    )) {
      buf.write(chunk);
    }
    return buf.toString().trim();
  }
}

/// محرك الذكاء الاصطناعي الشامل المتوافق مع معيار OpenAI (Universal OpenAI-Compatible Client):
/// 1) `ownerSession`: جلسة الرفيق الشخصي التفاعلي (`temperature: 0.7`)
/// 2) `supportSessionFor(wsId)`: جلسة الدعم الفني للمستخدمين (`temperature: 0.2`)
class DualPersonaAiEngine {
  DualPersonaAiEngine._();
  static final DualPersonaAiEngine instance = DualPersonaAiEngine._();

  String _apiKey = '';
  String _baseUrl = kDefaultAiEndpoint;
  String _modelId = kDefaultAiModel;
  String _systemPrompt = kOwnerSystemInstruction;

  /// الجلسة الأولى المستقلة: رفيق المالك الشخصي (الرفيق العفوي متعدد الاهتمامات).
  final ChatSession ownerSession = ChatSession(
    personaId: 'owner_companion',
    systemInstruction: kOwnerSystemInstruction,
    temperature: kOwnerTemperature,
    maxTokens: kDeepSeekMaxTokens,
  );

  /// الجلسات المستقلة للنمط الثاني: الدعم الفني للمستخدمين.
  final Map<String, ChatSession> _supportSessions = {};

  void syncApiKey(String key) {
    _apiKey = key.trim();
  }

  void syncSettings({
    String? apiKey,
    String? baseUrl,
    String? modelId,
    String? systemPrompt,
  }) {
    if (apiKey != null) _apiKey = apiKey.trim();
    if (baseUrl != null) {
      final u = baseUrl.trim();
      _baseUrl = u.isEmpty ? kDefaultAiEndpoint : u;
    }
    if (modelId != null) {
      final m = modelId.trim();
      _modelId = m.isEmpty ? kDefaultAiModel : m;
    }
    if (systemPrompt != null) {
      final p = systemPrompt.trim();
      _systemPrompt = p.isEmpty ? kOwnerSystemInstruction : p;
      ownerSession.systemInstruction = _systemPrompt;
    }
  }

  String get apiKey =>
      _apiKey.isNotEmpty ? _apiKey : Rtdb.instance.deepSeekApiKey.trim();

  String get deepSeekApiKey => apiKey;

  String get baseUrl {
    if (_baseUrl.trim().isNotEmpty) return _baseUrl.trim();
    final r = Rtdb.instance.aiBaseUrl.trim();
    return r.isNotEmpty ? r : kDefaultAiEndpoint;
  }

  String get modelId {
    if (_modelId.trim().isNotEmpty) return _modelId.trim();
    final r = Rtdb.instance.aiModelId.trim();
    return r.isNotEmpty ? r : kDefaultAiModel;
  }

  String get systemPrompt {
    if (_systemPrompt.trim().isNotEmpty) return _systemPrompt.trim();
    final r = Rtdb.instance.aiSystemPrompt.trim();
    return r.isNotEmpty ? r : kOwnerSystemInstruction;
  }

  bool get hasApiKey => apiKey.isNotEmpty;

  /// مرسل الطلبات الديناميكي (Dynamic Request Dispatcher) لأي مزود متوافق مع معيار OpenAI Chat Completions
  /// (OpenRouter, OpenAI, DeepSeek, Groq, Together, Ollama.. إلخ).
  Stream<String> streamDeepSeekChat({
    required List<Map<String, dynamic>> messages,
    String? apiKey,
    String? baseUrl,
    String? model,
    double temperature = kOwnerTemperature,
    int maxTokens = kDeepSeekMaxTokens,
    http.Client? httpClient,
  }) async* {
    final cleanKey = (apiKey ?? this.apiKey).trim();
    if (cleanKey.isEmpty) {
      throw Exception(
          'لم يتم إدخال مفتاح الواجهة (API Key) بعد. اضغط على أيقونة الترس (⚙️) لضبط الإعدادات.');
    }

    final targetUrl = (baseUrl ?? this.baseUrl).trim().isEmpty
        ? kDefaultAiEndpoint
        : (baseUrl ?? this.baseUrl).trim();
    var selectedModel = (model ?? modelId).trim().isEmpty
        ? kDefaultAiModel
        : (model ?? modelId).trim();

    final isGeminiNative = targetUrl.contains('generativelanguage.googleapis.com') &&
        !targetUrl.contains('/openai/');
    final isGeminiKeyOrModel = cleanKey.startsWith('AIza') ||
        selectedModel.toLowerCase().startsWith('gemini-') ||
        selectedModel.toLowerCase().startsWith('models/gemini-');

    // إذا وضع المستخدم مفتاح Gemini (يبدأ بـ AIza) أو اختار نموذج gemini-* بينما الرابط لا يزال افتراضياً لـ OpenRouter/DeepSeek،
    // أو اختار رابط Gemini المباشر، ندعم الاستدعاء بسلاسة تامة.
    if (isGeminiNative ||
        (cleanKey.startsWith('AIza') &&
            (targetUrl == kDefaultAiEndpoint ||
                targetUrl == kDeepSeekEndpoint))) {
      var cleanModelName = selectedModel;
      if (cleanModelName.contains('/')) {
        cleanModelName = cleanModelName.split('/').last;
      }
      if (!cleanModelName.startsWith('gemini-')) {
        cleanModelName = 'gemini-2.5-flash';
      }
      yield* _streamNativeGeminiChat(
        messages: messages,
        apiKey: cleanKey,
        model: cleanModelName,
        temperature: temperature,
        maxTokens: maxTokens,
        httpClient: httpClient,
      );
      return;
    }

    if (targetUrl.contains('generativelanguage.googleapis.com') &&
        targetUrl.contains('/openai/')) {
      if (selectedModel.startsWith('google/')) {
        selectedModel = selectedModel.substring('google/'.length);
      } else if (selectedModel.startsWith('models/')) {
        selectedModel = selectedModel.substring('models/'.length);
      }
      if (!selectedModel.startsWith('gemini-')) {
        selectedModel = 'gemini-2.5-flash';
      }
    } else if (isGeminiKeyOrModel &&
        targetUrl.contains('openrouter.ai') &&
        !selectedModel.contains('/')) {
      selectedModel = 'google/$selectedModel';
    }

    final Uri uri;
    try {
      uri = Uri.parse(targetUrl);
      if (!uri.hasScheme || uri.host.isEmpty) {
        throw const FormatException('Invalid URL');
      }
    } catch (_) {
      throw Exception(
          'رابط الخدمة (Base URL) غير صالح: $targetUrl — يرجى مراجعته من أيقونة الترس (⚙️).');
    }

    final client = httpClient ?? http.Client();
    final headers = buildOpenAiCompatibleHeaders(cleanKey);
    final payload = <String, dynamic>{
      'model': selectedModel,
      'messages': messages,
      'temperature': temperature,
    };

    http.Response res;
    try {
      res = await client
          .post(
            uri,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 45));
    } catch (e) {
      throw Exception(
          'تعذر الاتصال بخادم الذكاء الاصطناعي ($targetUrl). تحقق من اتصال الإنترنت أو صحة الرابط.');
    }

    final rawBody = utf8.decode(res.bodyBytes);
    if (res.statusCode != 200) {
      throw Exception(parseOpenAiError(res.statusCode, rawBody, selectedModel));
    }

    // 1) إذا أعاد الخادم تدفق SSE (data: ...)
    final trimmedBody = rawBody.trimLeft();
    if (trimmedBody.startsWith('data:')) {
      bool yieldedAny = false;
      for (final line in const LineSplitter().convert(rawBody)) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final dataStr = trimmed.substring(5).trim();
        if (dataStr.isEmpty || dataStr == '[DONE]') continue;
        try {
          final decoded = jsonDecode(dataStr);
          final chunk = _extractOpenAiContent(decoded);
          if (chunk.isNotEmpty) {
            yieldedAny = true;
            yield chunk;
          }
        } catch (_) {}
      }
      if (yieldedAny) return;
    }

    // 2) استجابة JSON قياسية متوافقة مع OpenAI Chat Completions
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map && decoded['error'] != null) {
        throw Exception(parseOpenAiError(400, rawBody, selectedModel));
      }
      final text = _extractOpenAiContent(decoded);
      if (text.isNotEmpty) {
        yield text;
        return;
      }
    } catch (e) {
      if (e.toString().contains('خطأ') ||
          e.toString().contains('401') ||
          e.toString().contains('404') ||
          e.toString().contains('429')) {
        rethrow;
      }
    }

    throw Exception('لم يتم استلام نص رد صالح من المزود ($selectedModel).');
  }

  /// استدعاء مباشر لواجهة Google Gemini الرسمية (`generateContent`) مع دعم كافة نماذج Gemini.
  Stream<String> _streamNativeGeminiChat({
    required List<Map<String, dynamic>> messages,
    required String apiKey,
    required String model,
    double temperature = kOwnerTemperature,
    int maxTokens = kDeepSeekMaxTokens,
    http.Client? httpClient,
  }) async* {
    final cleanModel = model.replaceAll(RegExp(r'^models/'), '').trim();
    final uri = Uri.parse(
      '$kGeminiNativeBaseUrl/$cleanModel:generateContent?key=${Uri.encodeQueryComponent(apiKey)}',
    );

    String systemText = '';
    final contents = <Map<String, Object?>>[];
    for (final m in messages) {
      final role = '${m['role'] ?? ''}'.trim();
      final content = '${m['content'] ?? ''}'.trim();
      if (content.isEmpty) continue;
      if (role == 'system') {
        systemText = systemText.isEmpty ? content : '$systemText\n$content';
      } else {
        contents.add({
          'role': (role == 'assistant' || role == 'model') ? 'model' : 'user',
          'parts': [
            {'text': content}
          ],
        });
      }
    }

    if (contents.isEmpty) {
      contents.add({
        'role': 'user',
        'parts': [
          {'text': 'مرحباً'}
        ],
      });
    }

    final body = <String, Object?>{
      if (systemText.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemText}
          ],
        },
      'contents': contents,
      'generationConfig': {
        'temperature': temperature,
        'maxOutputTokens': maxTokens,
      },
    };

    final client = httpClient ?? http.Client();
    http.Response res;
    try {
      res = await client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 45));
    } catch (_) {
      throw Exception(
          'تعذر الاتصال بخادم Google Gemini ($cleanModel). تحقق من اتصال الإنترنت أو المفتاح.');
    }

    final rawBody = utf8.decode(res.bodyBytes);
    if (res.statusCode != 200) {
      throw Exception(parseOpenAiError(res.statusCode, rawBody, cleanModel));
    }

    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map) {
        final candidates = decoded['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final first = candidates.first;
          if (first is Map) {
            final content = first['content'];
            if (content is Map) {
              final parts = content['parts'];
              if (parts is List && parts.isNotEmpty) {
                final buf = StringBuffer();
                for (final p in parts) {
                  if (p is Map && p['text'] != null) {
                    buf.write('${p['text']}');
                  }
                }
                final reply = buf.toString().trim();
                if (reply.isNotEmpty) {
                  yield reply;
                  return;
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    throw Exception('لم يتم استلام نص رد صالح من نموذج Gemini ($cleanModel).');
  }

  static String _extractOpenAiContent(Object? decoded) {
    if (decoded is! Map) return '';
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final first = choices.first;
    if (first is! Map) return '';
    final message = first['message'];
    if (message is Map && message['content'] != null) {
      return '${message['content']}';
    }
    final delta = first['delta'];
    if (delta is Map && delta['content'] != null) {
      return '${delta['content']}';
    }
    if (first['text'] != null) {
      return '${first['text']}';
    }
    return '';
  }

  static String parseOpenAiError(
      int status, String rawBody, [String model = '']) {
    String detail = '';
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map) {
          detail = asStr(err['message']);
        } else if (err is String) {
          detail = err;
        } else if (decoded['message'] != null) {
          detail = asStr(decoded['message']);
        }
      }
    } catch (_) {}

    if (status == 401 || status == 403) {
      return 'المفتاح غير صحيح أو غير مصرح به ($status): تحقق من صحة مفتاح الـ API Key في الإعدادات (⚙️).'
          '${detail.isNotEmpty ? ' ($detail)' : ''}';
    }
    if (status == 404) {
      return 'النموذج غير موجود أو رابط الخدمة غير صحيح (404): تأكد من كتابة اسم النموذج'
          '${model.isNotEmpty ? ' "$model"' : ''} ورابط الـ Endpoint بشكل صحيح في الإعدادات (⚙️).'
          '${detail.isNotEmpty ? ' ($detail)' : ''}';
    }
    if (status == 402 || status == 429) {
      return 'نفاد الرصيد أو تجاوز حد الطلبات المسموح ($status): يرجى شحن الرصيد لدى المزود أو الانتظار قليلاً.'
          '${detail.isNotEmpty ? ' ($detail)' : ''}';
    }
    if (detail.isNotEmpty) {
      return 'خطأ من مزود الذكاء الاصطناعي ($status): $detail';
    }
    return 'تعذر إتمام الطلب من المزود (رمز الحالة $status).';
  }

  /// الحصول على جلسة الدعم الفني المستقلة الخاصة بمنشأة معينة (`temperature: 0.2`).
  ChatSession supportSessionFor(String workspaceId) {
    return _supportSessions.putIfAbsent(
      workspaceId,
      () => ChatSession(
        personaId: 'client_support_$workspaceId',
        systemInstruction: kClientSupportSystemInstruction,
        temperature: kClientSupportTemperature,
        maxTokens: kDeepSeekMaxTokens,
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
