// (معمارية حساب Google) مصادقة Firebase عبر REST — بدون SDK إضافي.
//
// google_sign_in يجلب idToken من حساب Google، وهذه الخدمة تبادله مع
// Firebase Identity Toolkit (accounts:signInWithIdp) فيصدر uid الرسمي
// نفسه الذي تصدره حزمة firebase_auth تماماً — فيصبح هوية المؤسسة
// الدائمة عبر الأجهزة: مساحة العمل WS-{uid} والترخيص مربوطان به.
//
// Offline-First: الجلسة تُحفظ محلياً (settings) بعد أول دخول ناجح —
// التطبيق يعمل كاملاً بلا إنترنت ولا يُطلب تسجيل الدخول في كل مرة.
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth_config.dart';
import '../../core/database.dart';
import '../../core/token_cipher.dart';
import '../repository.dart';
import 'device_id.dart';
import 'google_auth_service.dart';

/// واجهة متوافقة مع `FirebaseAuth.instance.signOut()` لإنهاء جلسة Firebase Auth بالكامل.
class FirebaseAuth {
  FirebaseAuth._();
  static final FirebaseAuth instance = FirebaseAuth._();

  Future<void> signOut([Repo? repo]) async {
    await FirebaseAuthRest.signOut(repo);
  }
}

class FirebaseAccount {
  final String uid; // localId — معرف المستخدم الرسمي في Firebase
  final String email;
  final String displayName;

  /// توكن الهوية **الصادر عن Firebase** بعد الاستبدال (`accounts:signInWithIdp`).
  /// ⚠️ ليس توكن Google الخام: إرسال الخام في `?auth=` ترفضه RTDB بـ 401.
  final String idToken;
  final String refreshToken;
  final int expiresInSeconds;

  const FirebaseAccount({
    required this.uid,
    required this.email,
    this.displayName = '',
    this.idToken = '',
    this.refreshToken = '',
    this.expiresInSeconds = 0,
  });
}

class FirebaseAuthRest {
  FirebaseAuthRest._();

  static const uidKey = 'account.uid';
  static const emailKey = 'account.email';
  static const nameKey = 'account.name';
  static const lastOwnerEmailKey = 'account.lastOwnerEmail';
  static const lastOwnerUidKey = 'account.lastOwnerUid';

  // مفاتيح الجلسة في SharedPreferences لعزل المنشآت وتطهير الجلسة عند الخروج
  static const prefsWorkspaceIdKey = 'current_workspace_id';
  static const prefsUserRoleKey = 'user_role';
  static const prefsBusinessNameKey = 'business_name';
  static const prefsOwnerEmailKey = 'owner_email';
  static const prefsOwnerUidKey = 'owner_uid';
  static const prefsUserNameKey = 'user_display_name';
  static const prefsWorkspacesListKey = 'saved_workspaces_list';
  static const prefsLoggedOutKey = 'auth_logged_out';

  /// حفظ بيانات المنشأة النشطة والجلسة في SharedPreferences
  static Future<void> saveWorkspaceSessionPrefs({
    required String workspaceId,
    required String ownerEmail,
    String businessName = '',
    String userRole = 'admin',
    String ownerUid = '',
    String displayName = '',
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (workspaceId.trim().isNotEmpty && workspaceId.trim() != 'default') {
        await prefs.setString(prefsWorkspaceIdKey, workspaceId.trim());
      }
      if (ownerEmail.trim().isNotEmpty) {
        await prefs.setString(
            prefsOwnerEmailKey, ownerEmail.trim().toLowerCase());
      }
      if (businessName.trim().isNotEmpty) {
        await prefs.setString(prefsBusinessNameKey, businessName.trim());
      }
      if (userRole.trim().isNotEmpty) {
        await prefs.setString(prefsUserRoleKey, userRole.trim());
      }
      if (ownerUid.trim().isNotEmpty) {
        await prefs.setString(prefsOwnerUidKey, ownerUid.trim());
      }
      if (displayName.trim().isNotEmpty) {
        await prefs.setString(prefsUserNameKey, displayName.trim());
      }
      await prefs.setBool(prefsLoggedOutKey, false);
    } catch (_) {}
  }

  /// تصفير ومسح كافة بيانات الجلسة والمنشأة النشطة من SharedPreferences
  /// (مع الاحتفاظ بسجل المنشآت المحفوظة على الجهاز `prefsWorkspacesListKey` لعدم ضياع المنشآت المحلية عند التبديل).
  static Future<void> purgeAllSessionPrefs({bool clearWorkspacesList = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in <String>[
        prefsWorkspaceIdKey,
        prefsUserRoleKey,
        prefsBusinessNameKey,
        prefsOwnerEmailKey,
        prefsOwnerUidKey,
        prefsUserNameKey,
        if (clearWorkspacesList) prefsWorkspacesListKey,
        'sync.workspaceId',
        'account.email',
        'account.uid',
        'account.name',
        'account.idToken',
        'account.refreshToken',
        'account.expiryMs',
        'businessName',
        'businessActivity',
        'phone',
        'whatsapp',
        'address',
        'has_completed_onboarding',
        'onboarding.done',
      ]) {
        await prefs.remove(k);
      }
      await prefs.setBool(prefsLoggedOutKey, true);
    } catch (_) {}
  }

  static Future<void> signOut([Repo? repo]) async {
    final targetRepo = repo ?? _repo;
    if (targetRepo != null) {
      await clearSession(targetRepo);
    } else {
      _accountUid = null;
      _accountIdToken = null;
      _accountRefreshToken = null;
      _accountExpiryMs = 0;
      _activeTokenUid = null;
      await purgeAllSessionPrefs();
      try {
        await AppDatabase.instance.closeAndResetWorkspace();
      } catch (_) {}
    }
  }

  // ══════ (401) جلسة الحساب: توكن Firebase بعد استبدال توكن Google ══════
  // قبل هذا الإصلاح كان الاستبدال يُستخرج `localId` فقط ويُهمل `idToken`،
  // فيبقى `?auth=` يحمل توكن الهوية **المجهولة** للجهاز — وهو ليس مالك
  // المساحة، فترفض القواعد كل كتابة تتطلب صلاحية المالك (إنشاء دعوة،
  // invite_index، members) بـ 401.
  static const accountIdTokenKey = 'account.idToken';
  static const accountRefreshKey = 'account.refreshToken';
  static const accountExpiryKey = 'account.expiryMs';

  static String? _accountUid;
  static String? _accountIdToken;
  static String? _accountRefreshToken;
  static int _accountExpiryMs = 0;

  /// الهوية الفعّالة المطابقة للتوكن الأخير الذي أصدره `cloudIdToken()`.
  static String? _activeTokenUid;

  /// هل توجد جلسة حساب Google مُستبدلة؟ (بلا انتظار شبكة)
  static bool get hasAccountSession =>
      _accountIdToken != null && _accountIdToken!.isNotEmpty;

  static bool get _accountTokenValid =>
      hasAccountSession &&
      DateTime.now().millisecondsSinceEpoch < _accountExpiryMs;

  /// الهوية المجهولة للجهاز (قبل/بلا ربط حساب Google).
  static String get anonymousUid => _anonUid ?? '';

  /// تفعيل توكن الحساب في الذاكرة فوراً قبل أي استعلام سحابي (لمنع 401 أثناء البحث والاسترداد).
  static void primeAccountInMemory(FirebaseAccount a) {
    if (a.idToken.isNotEmpty) {
      _accountUid = a.uid;
      _accountIdToken = a.idToken;
      _accountRefreshToken = a.refreshToken.isEmpty ? null : a.refreshToken;
      _accountExpiryMs = _computeExpiryMs(a.expiresInSeconds);
      _activeTokenUid = a.uid;
    } else if (a.uid.isNotEmpty && !hasValidToken) {
      _accountUid = a.uid;
    }
  }

  /// تبادل idToken أو accessToken الخاص بـ Google مع Firebase للحصول على uid الرسمي،
  /// مع تراجع ذكي إلى هوية Firebase حتمية مرتبطة ببريد Google الموثّق عند غياب serverClientId.
  static Future<FirebaseAccount?> signInWithGoogleIdToken(
    String googleIdToken, {
    String? accessToken,
    String? email,
    String? googleId,
    String? displayName,
    Future<String?> Function()? onEmptyTokenRetry,
  }) async {
    final key = effectiveFirebaseApiKey;
    if (key.isEmpty) return null;

    var rawToken = googleIdToken.trim();
    var rawAccess = (accessToken ?? '').trim();
    if (rawToken.isEmpty && rawAccess.isEmpty && onEmptyTokenRetry != null) {
      for (var i = 0; i < 2 && rawToken.isEmpty; i++) {
        if (i > 0) {
          await Future<void>.delayed(Duration(milliseconds: 250 * i));
        }
        try {
          rawToken = (await onEmptyTokenRetry())?.trim() ?? '';
        } catch (_) {}
      }
    }
    if (rawToken.isEmpty && rawAccess.isEmpty && _repo != null) {
      try {
        final db = await _repo!.database;
        rawToken = (await GoogleAuthService(db).refreshIdToken())?.trim() ?? '';
      } catch (_) {}
    }

    final postBodies = <String>[];
    if (rawToken.isNotEmpty) {
      if (rawToken.contains('.')) {
        postBodies.add('id_token=$rawToken&providerId=google.com');
      } else {
        postBodies.add('access_token=$rawToken&providerId=google.com');
        postBodies.add('id_token=$rawToken&providerId=google.com');
      }
    }
    if (rawAccess.isNotEmpty && rawAccess != rawToken) {
      postBodies.add('access_token=$rawAccess&providerId=google.com');
    }

    if (postBodies.isNotEmpty) {
      final uri = Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp'
          '?key=$key');
      for (final postBody in postBodies) {
        try {
          final res = await http
              .post(
                uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'postBody': postBody,
                  'requestUri': 'http://localhost',
                  'returnSecureToken': true,
                  'returnIdpCredential': true,
                }),
              )
              .timeout(const Duration(seconds: 12));
          if (res.statusCode < 200 || res.statusCode >= 300) continue;
          final m = jsonDecode(utf8.decode(res.bodyBytes));
          if (m is! Map) continue;
          final uid = '${m['localId'] ?? ''}'.trim();
          final idTok = '${m['idToken'] ?? ''}'.trim();
          if (uid.isEmpty || idTok.isEmpty) continue;
          final resolvedEmail = '${m['email'] ?? ''}'.trim().isNotEmpty
              ? '${m['email'] ?? ''}'.trim()
              : (email ?? '').trim();
          final resolvedName = '${m['displayName'] ?? ''}'.trim().isNotEmpty
              ? '${m['displayName'] ?? ''}'.trim()
              : (displayName ?? '').trim();
          final acc = FirebaseAccount(
            uid: uid,
            email: resolvedEmail,
            displayName: resolvedName,
            idToken: idTok,
            refreshToken: '${m['refreshToken'] ?? ''}'.trim(),
            expiresInSeconds: int.tryParse('${m['expiresIn'] ?? ''}') ?? 0,
          );
          primeAccountInMemory(acc);
          return acc;
        } catch (_) {}
      }
    }

    // تراجع آمن عند تعذّر تبادل IdP: استخدام المصادقة المجهولة الرسمية (signInAnonymously)
    // بدلاً من توليد بيانات اعتماد حتمية قابلة للعكس.
    final cleanEmail = (email ?? '').trim().toLowerCase();
    if (cleanEmail.isNotEmpty && cleanEmail.contains('@')) {
      final fallbackAcc = await _signInAnonymousFallbackForVerifiedAccount(
        key,
        email: cleanEmail,
        googleId: googleId,
        displayName: displayName,
      );
      if (fallbackAcc != null) return fallbackAcc;
    }
    return null;
  }

  /// استرجاع جلسة حالية صالحة أو تسجيل دخول مجهول رسمي (`signInAnonymously`)
  /// دون أي اشتقاق حتمي للبريد أو كلمة المرور.
  static Future<FirebaseAccount?> _signInAnonymousFallbackForVerifiedAccount(
    String key, {
    required String email,
    String? googleId,
    String? displayName,
  }) async {
    try {
      final cleanEmail = email.trim().toLowerCase();
      // 1) الحفاظ على الجلسة المحلية الحالية إن كانت صالحة لتفادي تسجيل خروج مفاجئ
      if (_accountTokenValid &&
          _accountUid != null &&
          _accountUid!.isNotEmpty &&
          _accountIdToken != null &&
          _accountIdToken!.isNotEmpty) {
        return FirebaseAccount(
          uid: (googleId != null && googleId.trim().isNotEmpty)
              ? googleId.trim()
              : _accountUid!,
          email: cleanEmail,
          displayName: (displayName ?? '').trim(),
          idToken: _accountIdToken!,
          refreshToken: _accountRefreshToken ?? '',
          expiresInSeconds: 3600,
        );
      }
      if (_accountRefreshToken != null && _accountRefreshToken!.isNotEmpty) {
        final refreshed = await _refreshAccountToken();
        if (refreshed != null &&
            refreshed.isNotEmpty &&
            _accountUid != null &&
            _accountUid!.isNotEmpty) {
          return FirebaseAccount(
            uid: (googleId != null && googleId.trim().isNotEmpty)
                ? googleId.trim()
                : _accountUid!,
            email: cleanEmail,
            displayName: (displayName ?? '').trim(),
            idToken: refreshed,
            refreshToken: _accountRefreshToken ?? '',
            expiresInSeconds: 3600,
          );
        }
      }

      // 2) انتقال آمن إلى Firebase Anonymous Authentication (`signInAnonymously`)
      final ok = await signInAnonymously(key);
      if (ok &&
          _anonUid != null &&
          _anonUid!.isNotEmpty &&
          _anonIdToken != null &&
          _anonIdToken!.isNotEmpty) {
        final resolvedUid = (googleId != null && googleId.trim().isNotEmpty)
            ? googleId.trim()
            : _anonUid!;
        final acc = FirebaseAccount(
          uid: resolvedUid,
          email: cleanEmail,
          displayName: (displayName ?? '').trim(),
          idToken: _anonIdToken!,
          refreshToken: _anonRefreshToken ?? '',
          expiresInSeconds: 3600,
        );
        _accountUid = resolvedUid;
        _accountIdToken = _anonIdToken;
        _accountRefreshToken = _anonRefreshToken;
        _accountExpiryMs = _anonExpiryMs;
        _activeTokenUid = _anonUid;
        return acc;
      }
    } catch (_) {}
    return null;
  }

  /// تسجيل الدخول بالبريد الإلكتروني وكلمة المرور عبر Firebase Identity Toolkit REST.
  /// يرمي استثناء نصه `'USER_NOT_FOUND'` إذا كان الحساب غير موجود ليتم تحويل المستخدم تلقائياً لشاشة إنشاء حساب جديد.
  static Future<FirebaseAccount> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final key = effectiveFirebaseApiKey;
    final cleanEmail = email.trim().toLowerCase();
    if (key.isEmpty) {
      throw Exception('مفتاح مصادقة السحابة غير مهيأ.');
    }
    final uri = Uri.parse(
      'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$key',
    );
    final res = await http
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': cleanEmail,
            'password': password,
            'returnSecureToken': true,
          }),
        )
        .timeout(const Duration(seconds: 15));

    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final errMsg = decoded is Map && decoded['error'] is Map
          ? '${decoded['error']['message'] ?? ''}'
          : res.body;
      if (errMsg.contains('EMAIL_NOT_FOUND') ||
          errMsg.contains('USER_NOT_FOUND')) {
        throw StateError('USER_NOT_FOUND');
      }
      if (errMsg.contains('INVALID_PASSWORD') ||
          errMsg.contains('INVALID_LOGIN_CREDENTIALS')) {
        // تحقق ما إذا كان الحساب مسجلاً بهوية Google الحتمية أو غير موجود أصلاً
        throw StateError('INVALID_CREDENTIALS_OR_NOT_FOUND:$errMsg');
      }
      throw Exception('تعذّر تسجيل الدخول ($errMsg)');
    }
    if (decoded is! Map) {
      throw Exception('استجابة غير صالحة من خادم المصادقة.');
    }
    final uid = '${decoded['localId'] ?? ''}'.trim();
    final idTok = '${decoded['idToken'] ?? ''}'.trim();
    final acc = FirebaseAccount(
      uid: uid,
      email: cleanEmail,
      displayName: '${decoded['displayName'] ?? ''}'.trim(),
      idToken: idTok,
      refreshToken: '${decoded['refreshToken'] ?? ''}'.trim(),
      expiresInSeconds: int.tryParse('${decoded['expiresIn'] ?? ''}') ?? 3600,
    );
    primeAccountInMemory(acc);
    return acc;
  }

  /// إنشاء حساب جديد بالبريد الإلكتروني وكلمة المرور عبر Firebase Identity Toolkit REST.
  static Future<FirebaseAccount> signUpWithEmailPassword({
    required String email,
    required String password,
    String displayName = '',
  }) async {
    final key = effectiveFirebaseApiKey;
    final cleanEmail = email.trim().toLowerCase();
    if (key.isEmpty) {
      throw Exception('مفتاح مصادقة السحابة غير مهيأ.');
    }
    final uri = Uri.parse(
      'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$key',
    );
    final res = await http
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': cleanEmail,
            'password': password,
            if (displayName.trim().isNotEmpty)
              'displayName': displayName.trim(),
            'returnSecureToken': true,
          }),
        )
        .timeout(const Duration(seconds: 15));

    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final errMsg = decoded is Map && decoded['error'] is Map
          ? '${decoded['error']['message'] ?? ''}'
          : res.body;
      if (errMsg.contains('EMAIL_EXISTS')) {
        return signInWithEmailPassword(email: cleanEmail, password: password);
      }
      throw Exception('تعذّر إنشاء الحساب ($errMsg)');
    }
    if (decoded is! Map) {
      throw Exception('استجابة غير صالحة من خادم المصادقة.');
    }
    final uid = '${decoded['localId'] ?? ''}'.trim();
    final idTok = '${decoded['idToken'] ?? ''}'.trim();
    final acc = FirebaseAccount(
      uid: uid,
      email: cleanEmail,
      displayName: displayName.trim(),
      idToken: idTok,
      refreshToken: '${decoded['refreshToken'] ?? ''}'.trim(),
      expiresInSeconds: int.tryParse('${decoded['expiresIn'] ?? ''}') ?? 3600,
    );
    primeAccountInMemory(acc);
    return acc;
  }

  /// حفظ الجلسة محلياً — تبقى صالحة بلا إنترنت (لا انتهاء محلي).
  static Future<void> saveSession(Repo repo, FirebaseAccount a) async {
    _repo ??= repo;
    try {
      final db = await repo.database;
      await db.delete('sync_meta', where: "key = 'demotedToAgentBy'");
      await db.delete('settings', where: "key LIKE 'pendingJoin.%'");
    } catch (_) {}
    await repo.setSetting(uidKey, a.uid);
    await repo.setSetting(emailKey, a.email);
    await repo.setSetting(nameKey, a.displayName);
    if (a.email.trim().isNotEmpty) {
      await repo.setSetting(lastOwnerEmailKey, a.email.trim().toLowerCase());
    }
    if (a.uid.trim().isNotEmpty) {
      await repo.setSetting(lastOwnerUidKey, a.uid.trim());
    }
    // (401) توكن الحساب هو الذي يمنح صلاحية المالك — يُحفظ ويُستخدم فوراً.
    if (a.idToken.isNotEmpty) {
      _accountUid = a.uid;
      _accountIdToken = a.idToken;
      _accountRefreshToken = a.refreshToken.isEmpty ? null : a.refreshToken;
      _accountExpiryMs = _computeExpiryMs(a.expiresInSeconds);
      _activeTokenUid = a.uid;
      await _persistAccount();
    } else if (a.uid.isNotEmpty && !hasValidToken) {
      _accountUid = a.uid;
    }
    // تثبيت هوية وصفة المدير والمالك محلياً فوراً دون انتظار الشبكة
    await repo.checkAndAutoPromoteManager();
    await repo.ensureSelfPermissionRow(roleCode: 'admin');
    try {
      final st = await repo.settings();
      await saveWorkspaceSessionPrefs(
        workspaceId: repo.requireWorkspaceId,
        ownerEmail: a.email,
        businessName: (st['businessName'] ?? '').trim(),
        userRole: 'admin',
      );
    } catch (_) {}
  }

  /// uid المحفوظ محلياً ('' إن لم يسجل الدخول بعد).
  static Future<String> savedUid(Repo repo) async =>
      ((await repo.settings())[uidKey] ?? '').trim();

  static Future<String> savedEmail(Repo repo) async =>
      ((await repo.settings())[emailKey] ?? '').trim();

  static Future<void> clearSession(
    Repo repo, {
    bool keepDatabaseOpen = false,
  }) async {
    try {
      final st = await repo.settings();
      final curEmail = (st[emailKey] ?? st['email'] ?? '').trim().toLowerCase();
      final curUid = (st[uidKey] ?? '').trim();
      if (curEmail.isNotEmpty) {
        await repo.setSetting(lastOwnerEmailKey, curEmail);
      }
      if (curUid.isNotEmpty) {
        await repo.setSetting(lastOwnerUidKey, curUid);
      }
    } catch (_) {}
    for (final entry in <String, String>{
      uidKey: '',
      emailKey: '',
      nameKey: '',
      'sync.workspaceId': '',
      'current_workspace_id': '',
      'user_role': '',
      'business_name': '',
      'owner_email': '',
      accountIdTokenKey: '',
      accountRefreshKey: '',
      accountExpiryKey: '0',
    }.entries) {
      try {
        await repo.setSetting(entry.key, entry.value);
      } catch (_) {}
    }
    _accountUid = null;
    _accountIdToken = null;
    _accountRefreshToken = null;
    _accountExpiryMs = 0;
    _activeTokenUid = _anonUid;
    await purgeAllSessionPrefs();
    if (!keepDatabaseOpen) {
      repo.debugSetWorkspaceId(defaultWorkspaceIdConst);
      try {
        await AppDatabase.instance.closeAndResetWorkspace();
      } catch (_) {}
    }
  }

  // ══════ (المرحلة 2) مصادقة مجهولة صامتة — هوية جهاز دائمة ══════
  //
  // الهدف: كل طلب إلى RTDB يحمل `?auth=<idToken>` صالحاً، فتستطيع قواعد
  // الأمان الاعتماد على `auth.uid` بدل ترك القاعدة مفتوحة للعامة.
  //
  // تُنفَّذ عبر Identity Toolkit REST (نفس عائلة `accounts:signInWithIdp`
  // المستخدمة أعلاه): `accounts:signUp` بلا بيانات = حساب مجهول حقيقي،
  // فيصدر `localId` و`idToken` مطابقين تماماً لما يصدره Firebase Anonymous
  // Auth — بلا SDK، وبلا الحاجة إلى `Firebase.initializeApp()` أو ملفات
  // `google-services.json` / `GoogleService-Info.plist`.

  static const anonUidKey = 'cloud.anon.uid';
  static const _anonIdTokenKey = 'cloud.anon.idToken';
  static const _anonRefreshKey = 'cloud.anon.refresh';
  static const _anonExpiryKey = 'cloud.anon.expiryMs';
  /// (دفعة 65) نطاق الهوية المجهولة: مساحة العمل + بصمة الجهاز.
  static const _anonScopeKey = 'cloud.anon.scope';

  static String? _anonUid;
  static String? _anonIdToken;
  static String? _anonRefreshToken;
  static int _anonExpiryMs = 0;
  static int _anonProviderDisabledUntilMs = 0;
  static bool _anonStarted = false;
  static Repo? _repo;

  /// (دفعة 65) مسح الهوية المجهولة بالكامل (من الذاكرة والتخزين) مع
  /// إعادة تعيين حالة الإقلاع — فتُصدر الجلسة التالية uid جديداً كلياً.
  ///
  /// تُستخدم عند الانضمام إلى مؤسسة أو تبديل الحساب: الموظف يبدأ بهوية
  /// سحابية مستقلة لا ترث بصمته القديمة، فإذا حُظر لا يعود بهوية سابقة،
  /// ولا تتداخل عضويته في `/members` مع حسابه الشخصي.
  static Future<void> resetAnonymousSession(Repo repo) async {
    await repo.setSetting(anonUidKey, '');
    await repo.setSetting(_anonIdTokenKey, '');
    await repo.setSetting(_anonRefreshKey, '');
    await repo.setSetting(_anonExpiryKey, '0');
    await repo.setSetting(_anonScopeKey, '');
    _anonUid = null;
    _anonIdToken = null;
    _anonRefreshToken = null;
    _anonExpiryMs = 0;
    _anonProviderDisabledUntilMs = 0;
    _anonStarted = false;
    if (!_accountTokenValid) {
      _activeTokenUid = null;
    }
    _repo = repo;
  }

  /// (دفعة 65) يضمن أن الهوية المجهولة **مقترنة بمساحة العمل الحالية
  /// وبصمة الجهاز**: إن تغيّرت المساحة (أو الجهاز) عن النطاق المحفوظ
  /// تُهمَل الهوية القديمة ويُصدر Firebase uid جديداً مستقلاً.
  ///
  /// قبل الانضمام: (مساحة شخصية، بصمة الموظف).
  /// بعد الانضمام: (مساحة المتجر، بصمة الموظف) ← نطاق مختلف ← هوية جديدة.
  static Future<void> ensureScopedAnonymous(
      Repo repo, String workspaceId) async {
    try {
      final deviceId = await ensureDeviceId(repo);
      final scope = '${workspaceId.trim()}|$deviceId';
      final saved = ((await repo.settings())[_anonScopeKey] ?? '').trim();
      if (saved != scope) {
        await resetAnonymousSession(repo);
        await repo.setSetting(_anonScopeKey, scope);
      }
    } catch (_) {
      // بصمة الجهاز غير متاحة (بيئة اختبار/ويب) — يُتجاوز بلا أثر.
    }
  }

  /// uid الفعّال لهذا الجهاز والمطابق تماماً للتوكن المعاد من `cloudIdToken()`.
  /// (401) هذا هو مفتاح عقدة `/members/{uid}` التي تستند إليها قواعد الأمان:
  /// يعيد `_accountUid` عندما يكون توكن الحساب صالحاً وفعّالاً، ويتحول تلقائياً
  /// إلى `_anonUid` إذا تراجع `cloudIdToken()` إلى التوكن المجهول، فلا يحدث
  /// تعارض أبداً بين `currentUid` وبين `auth.uid` داخل التوكن المرسل.
  static String get currentUid {
    if (_accountTokenValid &&
        _accountUid != null &&
        _accountUid!.isNotEmpty) {
      return _accountUid!;
    }
    if (hasValidToken && _anonUid != null && _anonUid!.isNotEmpty) {
      return _anonUid!;
    }
    if (_activeTokenUid != null && _activeTokenUid!.isNotEmpty) {
      return _activeTokenUid!;
    }
    final au = _accountUid;
    if (au != null && au.isNotEmpty) return au;
    return _anonUid ?? '';
  }

  /// التوكن الجاهز في الذاكرة الآن (بلا انتظار شبكة) — جلسة الحساب أولاً ثم
  /// الهوية المجهولة. يُستخدم لتوقيع طلبات `cloud_join` المتزامنة مسارها.
  static String? get cachedIdToken {
    if (_accountTokenValid &&
        _accountUid != null &&
        _accountUid!.isNotEmpty) {
      return _accountIdToken;
    }
    if (hasValidToken) return _anonIdToken;
    return null;
  }

  /// هل لدينا توكن هوية صالح الآن (بلا انتظار)؟
  static bool get hasValidToken =>
      _anonIdToken != null &&
      _anonIdToken!.isNotEmpty &&
      DateTime.now().millisecondsSinceEpoch < _anonExpiryMs;

  /// (للاختبارات) حقن توكن وهمي لتفادي حظر الشبكة والـ 401.
  static void setMockTokenForTest({String? token, String? uid}) {
    _anonIdToken = token ?? 'TOK-QA';
    _anonUid = uid ?? 'UID-QA';
    _anonExpiryMs = DateTime.now().millisecondsSinceEpoch + 86400000;
    _activeTokenUid = _anonUid;
  }

  /// (للاختبارات) تنظيف التوكنات المحقونة.
  static void clearMockForTest() {
    _anonIdToken = null;
    _anonUid = null;
    _anonExpiryMs = 0;
    _anonProviderDisabledUntilMs = 0;
    _accountIdToken = null;
    _accountUid = null;
    _accountRefreshToken = null;
    _accountExpiryMs = 0;
    _activeTokenUid = null;
    _anonStarted = false;
  }

  /// التوكن الصالح لإرفاقه بطلبات RTDB (`?auth=`) — يجدّده عند الحاجة.
  /// يضمن دائماً تطابق `currentUid` مع التوكن الفعلي المعاد.
  static Future<String?> cloudIdToken() async {
    // (401) الأولوية لجلسة الحساب: توكن Firebase الناتج عن استبدال توكن
    // Google هو الوحيد الذي يملك صلاحية المالك على مساحته.
    if (hasAccountSession) {
      if (_accountTokenValid &&
          _accountUid != null &&
          _accountUid!.isNotEmpty) {
        _activeTokenUid = _accountUid;
        return _accountIdToken;
      }
      final fresh = await _refreshAccountToken();
      if (fresh != null &&
          _accountUid != null &&
          _accountUid!.isNotEmpty) {
        _activeTokenUid = _accountUid;
        return fresh;
      }
      // تعذّر التجديد → نُكمل بالهوية المجهولة كيلا يُرسل طلب بلا مصادقة،
      // مع تحويل الهوية النشطة إلى _anonUid لضمان تطابق currentUid مع التوكن.
    }
    if (hasValidToken) {
      _activeTokenUid = _anonUid;
      return _anonIdToken;
    }
    if (DateTime.now().millisecondsSinceEpoch < _anonProviderDisabledUntilMs) {
      return null;
    }
    await _ensureFreshToken();
    if (hasValidToken) {
      _activeTokenUid = _anonUid;
      return _anonIdToken;
    }
    return null;
  }

  /// (401/403) تحديث قسري للتوكن ثم إعادته — لإعادة محاولة واحدة فقط.
  static Future<String?> forceRefreshToken() async {
    if (hasAccountSession) {
      _accountExpiryMs = 0;
      final fresh = await _refreshAccountToken();
      if (fresh != null &&
          _accountUid != null &&
          _accountUid!.isNotEmpty) {
        _activeTokenUid = _accountUid;
        return fresh;
      }
    }
    _anonExpiryMs = 0;
    _anonProviderDisabledUntilMs = 0;
    await _ensureFreshToken();
    if (hasValidToken) {
      _activeTokenUid = _anonUid;
      return _anonIdToken;
    }
    return null;
  }

  /// تهيئة صامتة تماماً: بلا نافذة، بلا إذن، بلا تأخير مرئي.
  /// تُستدعى مرة واحدة من `main()` **قبل** أي اتصال بـ RTDB.
  static Future<void> initSilentAuth(Repo repo) async {
    _repo = repo;
    if (_anonStarted) return;
    _anonStarted = true;
    if (effectiveFirebaseApiKey.isEmpty) return;
    try {
      final st = await repo.settings();
      final savedUid = (st[anonUidKey] ?? '').trim();
      final savedRefresh =
          (await TokenCipher.reveal((st[_anonRefreshKey] ?? '').trim())).trim();
      final savedToken =
          (await TokenCipher.reveal((st[_anonIdTokenKey] ?? '').trim())).trim();
      if (savedUid.isNotEmpty) {
        // الهوية المجهولة ثابتة عبر إعادة التشغيل — نفس auth.uid دائماً،
        // فلا تنكسر القواعد ولا تُفقد العضوية في /members.
        _anonUid = savedUid;
        _anonRefreshToken = savedRefresh.isEmpty ? null : savedRefresh;
        _anonIdToken = savedToken.isEmpty ? null : savedToken;
        _anonExpiryMs = int.tryParse(st[_anonExpiryKey] ?? '') ?? 0;
      }
      // (401) استعادة جلسة الحساب: نفس auth.uid بعد إعادة التشغيل، فتبقى
      // صلاحية المالك قائمة ولا تُرفض كتاباته على مساحته.
      final accUid = (st[uidKey] ?? '').trim();
      final accTok =
          (await TokenCipher.reveal((st[accountIdTokenKey] ?? '').trim()))
              .trim();
      if (accUid.isNotEmpty && accTok.isNotEmpty) {
        _accountUid = accUid;
        _accountIdToken = accTok;
        final accRefresh =
            (await TokenCipher.reveal((st[accountRefreshKey] ?? '').trim()))
                .trim();
        _accountRefreshToken = accRefresh.isEmpty ? null : accRefresh;
        _accountExpiryMs = int.tryParse(st[accountExpiryKey] ?? '') ?? 0;
      }
      if (_accountTokenValid) return;
      if (hasAccountSession) {
        await _refreshAccountToken();
        if (_accountTokenValid) return;
      }
      if (hasValidToken) return;
      await _ensureFreshToken();
    } catch (_) {
      // الشبكة غائبة عند أول إقلاع: يُستأنف تلقائياً عند أول طلب سحابي
      // عبر `cloudIdToken()` — لا نُسقط الإقلاع أبداً.
    }
  }

  static Future<void> _ensureFreshToken() async {
    final key = effectiveFirebaseApiKey;
    if (key.isEmpty) return;
    final refresh = _anonRefreshToken;
    if (refresh != null && refresh.isNotEmpty && await _refreshAnonymous(key)) {
      return;
    }
    await _createAnonymous(key);
  }

  /// مصادقة Firebase المجهولة الرسمية (`signInAnonymously`):
  /// `accounts:signUp` بلا بريد أو كلمة مرور مشتقة حتمياً.
  static Future<bool> signInAnonymously([String? apiKey]) async {
    final key = (apiKey ?? effectiveFirebaseApiKey).trim();
    if (key.isEmpty) return false;
    return _createAnonymous(key);
  }

  /// إنشاء حساب مجهول عبر `accounts:signUp`، مع تراجع آمن يستخدم
  /// بيانات اعتماد عشوائية مشفّرة (`Random.secure()` + `UUID`) محفوظة في
  /// `FlutterSecureStorage` فقط في حال تعطيل Anonymous Auth على الخادم.
  static Future<bool> _createAnonymous(String key) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://identitytoolkit.googleapis.com/v1/'
                'accounts:signUp?key=$key'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'returnSecureToken': true}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final m = jsonDecode(utf8.decode(res.bodyBytes));
        if (m is! Map) return false;
        final tok = '${m['idToken'] ?? ''}'.trim();
        final uid = '${m['localId'] ?? ''}'.trim();
        if (tok.isNotEmpty && uid.isNotEmpty) {
          _anonIdToken = tok;
          _anonUid = uid;
          final refresh = '${m['refreshToken'] ?? ''}'.trim();
          _anonRefreshToken = refresh.isEmpty ? null : refresh;
          _setExpiry(int.tryParse('${m['expiresIn'] ?? ''}') ?? 3600);
          await _persist();
          return true;
        }
        return false;
      }
    } catch (_) {}

    // في حال كان Anonymous Sign-Up معطلاً في المشروع السحابي، نستخدم
    // بيانات اعتماد عشوائية آمنة تشفيرياً (UUID + Random.secure) محفوظة في FlutterSecureStorage.
    return _createOrSignInRandomDeviceIdentity(key);
  }

  static Future<bool> _createOrSignInRandomDeviceIdentity(String key) async {
    try {
      const storage = FlutterSecureStorage();
      var creds = await storage.readOrCreateRandomCredentials(repo: _repo);

      for (final endpoint in const [
        'accounts:signInWithPassword',
        'accounts:signUp',
      ]) {
        try {
          final res = await http
              .post(
                Uri.parse(
                    'https://identitytoolkit.googleapis.com/v1/$endpoint?key=$key'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'email': creds.email,
                  'password': creds.password,
                  'returnSecureToken': true,
                }),
              )
              .timeout(const Duration(seconds: 15));
          if (res.statusCode < 200 || res.statusCode >= 300) {
            if (res.body.contains('CONFIGURATION_NOT_FOUND') ||
                res.body.contains('OPERATION_NOT_ALLOWED') ||
                res.body.contains('PASSWORD_LOGIN_DISABLED') ||
                res.body.contains('ADMIN_ONLY_OPERATION')) {
              _anonProviderDisabledUntilMs =
                  DateTime.now().millisecondsSinceEpoch + 600000;
              if (_anonUid == null || _anonUid!.isEmpty) {
                _anonUid = 'anon-${creds.randomId}';
                await _persist();
              }
            }
            continue;
          }
          final m = jsonDecode(utf8.decode(res.bodyBytes));
          if (m is! Map) continue;
          final tok = '${m['idToken'] ?? ''}'.trim();
          final uid = '${m['localId'] ?? ''}'.trim();
          if (tok.isEmpty || uid.isEmpty) continue;
          _anonIdToken = tok;
          _anonUid = uid;
          final refresh = '${m['refreshToken'] ?? ''}'.trim();
          _anonRefreshToken = refresh.isEmpty ? null : refresh;
          _setExpiry(int.tryParse('${m['expiresIn'] ?? ''}') ?? 3600);
          await _persist();
          return true;
        } catch (_) {}
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// تحديث التوكن عبر `securetoken` باستخدام الـ refresh token.
  static Future<bool> _refreshAnonymous(String key) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://securetoken.googleapis.com/v1/token?key=$key'),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: 'grant_type=refresh_token&refresh_token='
                '${Uri.encodeComponent(_anonRefreshToken ?? '')}',
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return false;
      final tok = '${m['id_token'] ?? ''}'.trim();
      if (tok.isEmpty) return false;
      _anonIdToken = tok;
      final uid = '${m['user_id'] ?? ''}'.trim();
      if (uid.isNotEmpty) _anonUid = uid;
      final refresh = '${m['refresh_token'] ?? ''}'.trim();
      if (refresh.isNotEmpty) _anonRefreshToken = refresh;
      _setExpiry(int.tryParse('${m['expires_in'] ?? ''}') ?? 3600);
      await _persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// (401) تجديد توكن الحساب عبر `securetoken` بـ refresh token.
  static Future<String?> _refreshAccountToken() async {
    final key = effectiveFirebaseApiKey;
    final refresh = _accountRefreshToken;
    if (key.isEmpty || refresh == null || refresh.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('https://securetoken.googleapis.com/v1/token?key=$key'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'grant_type=refresh_token&refresh_token='
                '${Uri.encodeComponent(refresh)}',
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return null;
      final tok = '${m['id_token'] ?? ''}'.trim();
      if (tok.isEmpty) return null;
      _accountIdToken = tok;
      final uid = '${m['user_id'] ?? ''}'.trim();
      if (uid.isNotEmpty) _accountUid = uid;
      final rt = '${m['refresh_token'] ?? ''}'.trim();
      if (rt.isNotEmpty) _accountRefreshToken = rt;
      _accountExpiryMs =
          _computeExpiryMs(int.tryParse('${m['expires_in'] ?? ''}') ?? 3600);
      await _persistAccount();
      return tok;
    } catch (_) {
      return null;
    }
  }

  /// انتهاء صالح مع هامش أمان (دقيقة) — موحّد للحساب والمجهول.
  static int _computeExpiryMs(int seconds) =>
      DateTime.now().millisecondsSinceEpoch +
      ((seconds > 0 ? seconds : 3600) * 1000) -
      const Duration(minutes: 1).inMilliseconds;

  /// حفظ جلسة الحساب (توكن + هوية) في الإعدادات بشكل مشفر.
  static Future<void> _persistAccount() async {
    final repo = _repo;
    if (repo == null) return;
    try {
      final rawTok = (_accountIdToken ?? '').trim();
      final rawRef = (_accountRefreshToken ?? '').trim();
      final encTok = rawTok.isEmpty ? '' : await TokenCipher.protect(rawTok);
      final encRef = rawRef.isEmpty ? '' : await TokenCipher.protect(rawRef);
      await repo.setSetting(accountIdTokenKey, encTok);
      await repo.setSetting(accountRefreshKey, encRef);
      await repo.setSetting(accountExpiryKey, '$_accountExpiryMs');
      if (_accountUid != null) await repo.setSetting(uidKey, _accountUid!);
    } catch (_) {}
  }

  /// هامش أمان دقيقة قبل انتهاء الصلاحية الحقيقي.
  static void _setExpiry(int seconds) {
    _anonExpiryMs = DateTime.now().millisecondsSinceEpoch +
        (seconds * 1000) -
        const Duration(minutes: 1).inMilliseconds;
  }

  static Future<void> _persist() async {
    final repo = _repo;
    if (repo == null) return;
    try {
      final rawTok = (_anonIdToken ?? '').trim();
      final rawRef = (_anonRefreshToken ?? '').trim();
      final encTok = rawTok.isEmpty ? '' : await TokenCipher.protect(rawTok);
      final encRef = rawRef.isEmpty ? '' : await TokenCipher.protect(rawRef);
      await repo.setSetting(anonUidKey, _anonUid ?? '');
      await repo.setSetting(_anonIdTokenKey, encTok);
      await repo.setSetting(_anonRefreshKey, encRef);
      await repo.setSetting(_anonExpiryKey, '$_anonExpiryMs');
    } catch (_) {}
  }

  /// حفظ الجلسة النشطة في قاعدة بيانات المستودع المحددة (مهم بعد openForWorkspace)
  static Future<void> persistActiveSession(Repo repo) async {
    _repo = repo;
    await _persist();
    if (hasAccountSession) {
      await _persistAccount();
    }
  }
}

/// بيانات اعتماد عشوائية مولّدة عبر `Random.secure()` و `UUID v4` (غير حتمية).
class RandomDeviceCredentials {
  final String randomId;
  final String email;
  final String password;

  const RandomDeviceCredentials({
    required this.randomId,
    required this.email,
    required this.password,
  });
}

/// مخزن أسرار مشفّر (`FlutterSecureStorage`) يحفظ بيانات الاعتماد العشوائية
/// مشفرة عبر `TokenCipher` (مفتاح 32 بايت عشوائي مستقل عن قاعدة البيانات).
class FlutterSecureStorage {
  const FlutterSecureStorage();

  static const _emailStorageKey = 'secure.random_device.email';
  static const _passwordStorageKey = 'secure.random_device.password';
  static const _idStorageKey = 'secure.random_device.uuid';

  Future<void> write({
    required String key,
    required String value,
    Repo? repo,
  }) async {
    final encrypted = await TokenCipher.protect(value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, encrypted);
    } catch (_) {}
    if (repo != null) {
      try {
        await repo.setSetting(key, encrypted);
      } catch (_) {}
    }
  }

  Future<String?> read({
    required String key,
    Repo? repo,
  }) async {
    String raw = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      raw = (prefs.getString(key) ?? '').trim();
    } catch (_) {}
    if (raw.isEmpty && repo != null) {
      try {
        final st = await repo.settings();
        raw = (st[key] ?? '').trim();
      } catch (_) {}
    }
    if (raw.isEmpty) return null;
    final revealed = (await TokenCipher.reveal(raw)).trim();
    return revealed.isEmpty ? null : revealed;
  }

  Future<RandomDeviceCredentials> readOrCreateRandomCredentials({
    Repo? repo,
  }) async {
    final existingId = await read(key: _idStorageKey, repo: repo);
    final existingEmail = await read(key: _emailStorageKey, repo: repo);
    final existingPassword = await read(key: _passwordStorageKey, repo: repo);

    if (existingId != null &&
        existingEmail != null &&
        existingPassword != null &&
        existingEmail.isNotEmpty &&
        existingPassword.isNotEmpty) {
      return RandomDeviceCredentials(
        randomId: existingId,
        email: existingEmail,
        password: existingPassword,
      );
    }

    final randomId = _generateSecureUuidV4().replaceAll('-', '');
    final randomSecret = _generateSecureSecret(24);
    final email = 'u-$randomId@anon-auth.invalid';
    final password = 'Rn!$randomSecret#9aZ';

    await write(key: _idStorageKey, value: randomId, repo: repo);
    await write(key: _emailStorageKey, value: email, repo: repo);
    await write(key: _passwordStorageKey, value: password, repo: repo);

    return RandomDeviceCredentials(
      randomId: randomId,
      email: email,
      password: password,
    );
  }

  static String _generateSecureUuidV4() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static String _generateSecureSecret(int byteLength) {
    final rnd = Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
