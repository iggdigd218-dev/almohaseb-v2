import 'dart:async';

// خدمة المصادقة بـ Google.
// تُستخدم لإثبات هوية المالك وربط Workspace بحساب Google.
// النطاقات المطلوبة محدودة: email + openid + profile (لا Drive هنا).

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/auth_config.dart';
import '../../core/database.dart';
import '../../core/token_cipher.dart';
import '../../core/platform_info.dart';

class GoogleUser {
  final String id; // Google sub (subject) ثابت لكل حساب
  final String email;
  final String? displayName;
  final String? photoUrl;
  final String? idToken; // يُستخدم محليًا فقط للمصادقة مع Backend المستقبلي
  final String? accessToken; // يُستخدم للتبادل مع Firebase Identity Toolkit عند غياب serverClientId
  final DateTime signedInAt;

  const GoogleUser({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
    this.idToken,
    this.accessToken,
    required this.signedInAt,
  });
}

class GoogleAuthResult {
  final GoogleUser? user;
  final String? error;
  const GoogleAuthResult.ok(this.user) : error = null;
  const GoogleAuthResult.fail(this.error) : user = null;
  bool get ok => user != null;
}

/// نطاق النسخ الاحتياطي — مجلد التطبيق الخاص (`appDataFolder`) داخل Drive.
const String kDriveAppDataScope =
    'https://www.googleapis.com/auth/drive.appdata';

/// نطاقات المصادقة وتحديد الهوية الأساسية (سريعة وخفيفة وتفتح نافذة الحساب فوراً).
const List<String> kAuthGoogleScopes = <String>[
  'email',
  'profile',
];

/// النطاقات الموسعة لخدمة النسخ السحابي على Google Drive.
const List<String> kDriveGoogleScopes = <String>[
  'email',
  'profile',
  kDriveAppDataScope,
];

/// النطاقات الموحّدة للتطبيق (تشمل صلاحية النسخ السحابي لتظهر أذونات Google للموافقة عليها عند التسجيل).
const List<String> kUnifiedGoogleScopes = kDriveGoogleScopes;

/// إنشاء كائن `GoogleSignIn`.
///
/// يطلب النطاقات الموحدة (البريد + الملف الشخصي + مجلد بيانات التطبيق السحابي)
/// لتظهر شاشة أذونات Google للموافقة عليها رسمياً عند التسجيل.
GoogleSignIn? createUnifiedGoogleSignIn({bool forDrive = true}) {
  try {
    return GoogleSignIn(
      scopes: forDrive ? kDriveGoogleScopes : kAuthGoogleScopes,
      serverClientId:
          kGoogleServerClientId.isEmpty ? null : kGoogleServerClientId,
    );
  } catch (e, st) {
    debugPrint('GoogleSignIn initialization failed: $e');
    debugPrint('$st');
    return null;
  }
}

class GoogleAuthService {
  final Database db;
  GoogleSignIn? _googleSignIn;

  GoogleAuthService(this.db);

  /// المثال الموحّد (يعيد null على منصات لا تدعمه كويندوز/لينكس).
  GoogleSignIn? _ensureSignIn() {
    _googleSignIn ??= createUnifiedGoogleSignIn(forDrive: true);
    return _googleSignIn;
  }

  /// استعادة الجلسة المحفوظة من جدول google_auth (بدون فتح نافذة تسجيل).
  Future<GoogleUser?> currentUserFromDb() async {
    final rows = await db.query('google_auth', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final gid = r['google_id'] as String?;
    if (gid == null || gid.isEmpty) return null;
    final signedStr = r['signed_in_at'] as String?;
    // فك تعمية التوكن المخزّن (القيم القديمة نص صريح تمر كما هي).
    final storedTok = (r['id_token'] as String?) ?? '';
    final tok =
        storedTok.isEmpty ? storedTok : await TokenCipher.reveal(storedTok);
    return GoogleUser(
      id: gid,
      email: (r['email'] as String?) ?? '',
      displayName: r['display_name'] as String?,
      photoUrl: r['photo_url'] as String?,
      idToken: tok,
      accessToken: tok,
      signedInAt: signedStr != null
          ? DateTime.tryParse(signedStr) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  /// محاولة استعادة الجلسة بصمت من Google أيضًا (في حال كانت الجلسة في الذاكرة).
  /// يقرأ السجل المحلي فوراً بدون تعليق الإقلاع، ويحدّث التوكن في الخلفية بمهلة صارمة.
  Future<GoogleAuthResult> restoreSession() async {
    final cached = await currentUserFromDb();
    final gs = _ensureSignIn();
    if (gs == null) {
      if (cached != null) return GoogleAuthResult.ok(cached);
      return GoogleAuthResult.fail(isPlatformSupportingGoogleSignIn()
          ? 'تعذّر تهيئة خدمة Google على هذا الجهاز — حدّث خدمات Google Play ثم أعد المحاولة.'
          : 'تسجيل الدخول بـ Google غير متاح على هذه المنصة حاليًا');
    }
    if (cached != null) {
      // تحديث صامت بالخلفية دون تعليق إقلاع التطبيق إطلاقاً
      unawaited(() async {
        try {
          final a = gs.currentUser ??
              await gs
                  .signInSilently(suppressErrors: true)
                  .timeout(const Duration(seconds: 5), onTimeout: () => null);
          if (a != null) {
            final tokens = await _extractTokensWithRetry(a);
            final u = _mapAccount(
              a,
              tokens.idToken ?? cached.idToken,
              accessToken: tokens.accessToken ?? cached.accessToken,
            );
            await _persist(u);
          }
        } catch (_) {}
      }());
      return GoogleAuthResult.ok(cached);
    }
    // إن لم تكن هناك جلسة Google محفوظة مسبقاً في قاعدة البيانات المحلية (cached == null)،
    // لا نستدعي signInSilently تلقائياً عند إقلاع التطبيق لئلا يُسجَّل دخول المستخدم
    // بصمت وتُنشأ له مجموعة تلقائياً عند تثبيت التطبيق لأول مرة على جهاز جديد.
    return const GoogleAuthResult.ok(null);
  }

  /// استعادة جلسة وتوكنات Google بصمت (signInSilently) وتحديث جدول google_auth والإعدادات.
  /// يُستدعى عند فتح شاشة النسخ الاحتياطي (Google Drive Backup) لاستعادة توكنات Drive فوراً.
  Future<GoogleUser?> signInSilently() async {
    try {
      final gs = _ensureSignIn();
      if (gs == null) return await currentUserFromDb();
      final a = gs.currentUser ??
          await gs
              .signInSilently(suppressErrors: true)
              .timeout(const Duration(seconds: 6), onTimeout: () => null);
      if (a != null) {
        final cached = await currentUserFromDb();
        final tokens = await _extractTokensWithRetry(a);
        final u = _mapAccount(
          a,
          tokens.idToken ?? cached?.idToken,
          accessToken: tokens.accessToken ?? cached?.accessToken,
        );
        await _persist(u);
        return u;
      }
    } catch (_) {}
    return await currentUserFromDb();
  }

  /// استخراج `idToken` و `accessToken` من حساب Google مع إعادة المحاولة تلقائياً.
  Future<({String? idToken, String? accessToken})> _extractTokensWithRetry(
    GoogleSignInAccount a, {
    int maxAttempts = 2,
  }) async {
    String? bestAccess;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        if (attempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
          try {
            await a.clearAuthCache().timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
        final auth =
            await a.authentication.timeout(const Duration(seconds: 6));
        final idTok = auth.idToken?.trim() ?? '';
        final accTok = auth.accessToken?.trim() ?? '';
        if (accTok.isNotEmpty) bestAccess = accTok;
        if (idTok.isNotEmpty) {
          return (
            idToken: idTok,
            accessToken: accTok.isNotEmpty ? accTok : bestAccess,
          );
        }
        // على أندرويد عند عدم ضبط serverClientId يعود accessToken صالحاً فوراً بينما idToken فارغ
        if (accTok.isNotEmpty && kGoogleServerClientId.isEmpty) {
          return (idToken: null, accessToken: accTok);
        }
      } catch (_) {}
    }
    return (idToken: null, accessToken: bestAccess);
  }

  /// إعادة محاولة جلب `idToken` أو `accessToken` لحساب Google النشط أو المحفوظ.
  Future<String?> refreshIdToken() async {
    try {
      final gs = _ensureSignIn();
      if (gs != null) {
        final a = gs.currentUser ??
            await gs
                .signInSilently(suppressErrors: true)
                .timeout(const Duration(seconds: 5), onTimeout: () => null);
        if (a != null) {
          final tokens = await _extractTokensWithRetry(a, maxAttempts: 2);
          final effective = (tokens.idToken != null && tokens.idToken!.isNotEmpty)
              ? tokens.idToken
              : tokens.accessToken;
          if (effective != null && effective.isNotEmpty) {
            final u = _mapAccount(
              a,
              tokens.idToken,
              accessToken: tokens.accessToken,
            );
            await _persist(u);
            return effective;
          }
        }
      }
    } catch (_) {}
    final cached = await currentUserFromDb();
    final saved = cached?.idToken?.trim() ?? '';
    return saved.isNotEmpty ? saved : null;
  }

  /// تسجيل الدخول (يفتح نافذة Google للمستخدم) مع حماية صارمة ضد التعليق عند اختيار الحساب.
  Future<GoogleAuthResult> signIn({bool forceAccountPicker = true}) async {
    final gs = _ensureSignIn();
    final supported = isPlatformSupportingGoogleSignIn();
    if (gs == null) {
      return GoogleAuthResult.fail(supported
          ? 'تعذّر تهيئة خدمة Google على هذا الجهاز — حدّث «خدمات Google Play» ثم أعد المحاولة.'
          : 'تسجيل الدخول بـ Google متاح على الأندرويد والآيفون.\n'
              'يمكنك استخدام التطبيق محليًا بدون حساب Google.');
    }
    try {
      // ضمان فتح نافذة اختيار حساب Google دائماً ليتمكن المستخدم من اختيار أي بريد بحرية
      if (forceAccountPicker || gs.currentUser != null) {
        try {
          await gs.signOut().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }

      GoogleSignInAccount? a;
      try {
        a = await gs.signIn().timeout(const Duration(seconds: 25));
      } on TimeoutException {
        // في حال تعليق Play Services بعد اختيار الحساب، نلتقط الحساب المختار إن وُجد في currentUser أو signInSilently
        a = gs.currentUser ??
            await gs
                .signInSilently(suppressErrors: true)
                .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (a == null) rethrow;
      }
      if (a == null) {
        return const GoogleAuthResult.fail('تم إلغاء تسجيل الدخول');
      }
      final tokens = await _extractTokensWithRetry(a, maxAttempts: 2);
      final u = _mapAccount(
        a,
        tokens.idToken,
        accessToken: tokens.accessToken,
      );
      await _persist(u);
      return GoogleAuthResult.ok(u);
    } catch (e, st) {
      debugPrint('GoogleSignIn signIn failed: $e');
      debugPrint('$st');
      final s = '$e';
      if (!supported) {
        return const GoogleAuthResult.fail(
          'تسجيل الدخول بـ Google متاح على الأندرويد والآيفون.',
        );
      }
      if (s.contains('DEVELOPER_ERROR') || s.contains('10:')) {
        return const GoogleAuthResult.fail(
          'تعذّر إتمام تسجيل الدخول عبر Google (خطأ إعداد 10):\n'
          'تحقّق من إضافة بصمة SHA-1 للتطبيق في إعدادات Firebase/Google Cloud '
          'ومن تطابق معرّف العميل.',
        );
      }
      if (e is TimeoutException || s.contains('deadline') || s.contains('timeout')) {
        return const GoogleAuthResult.fail(
          'انتهت مهلة استجابة Google. تأكد من اتصال الإنترنت وخدمات Google Play ثم أعد المحاولة.',
        );
      }
      if (s.contains('network_error') || s.contains('7:')) {
        return const GoogleAuthResult.fail(
          'تعذّر الاتصال بخوادم Google — تحقّق من الإنترنت ثم أعد المحاولة.',
        );
      }
      return GoogleAuthResult.fail('تعذّر تسجيل الدخول: $e');
    }
  }

  Future<void> signOut({bool keepDatabaseOpen = false}) async {
    final gs = _ensureSignIn();
    try {
      await gs?.disconnect().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await gs?.signOut().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      if (db.isOpen) {
        await _clear();
      }
    } catch (_) {}
    if (!keepDatabaseOpen) {
      await AppDatabase.instance.closeAndResetWorkspace();
    }
  }

  GoogleUser _mapAccount(
    GoogleSignInAccount a,
    String? idToken, {
    String? accessToken,
  }) {
    final cleanId = (idToken ?? '').trim();
    final cleanAcc = (accessToken ?? '').trim();
    return GoogleUser(
      id: a.id,
      email: a.email,
      displayName: a.displayName,
      photoUrl: a.photoUrl,
      idToken: cleanId.isNotEmpty ? cleanId : (cleanAcc.isNotEmpty ? cleanAcc : null),
      accessToken: cleanAcc.isNotEmpty ? cleanAcc : null,
      signedInAt: DateTime.now(),
    );
  }

  Future<void> _persist(GoogleUser u) async {
    // التوكن يُعمّى قبل التخزين — لا نص صريح في SQLite.
    final tok = (u.idToken == null || u.idToken!.isEmpty)
        ? ''
        : await TokenCipher.protect(u.idToken!);
    await db.insert(
        'google_auth',
        {
          'id': 1,
          'google_id': u.id,
          'email': u.email,
          'display_name': u.displayName ?? '',
          'photo_url': u.photoUrl ?? '',
          'id_token': tok,
          'signed_in_at': u.signedInAt.toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    final cleanEmail = u.email.trim().toLowerCase();
    if (cleanEmail.isNotEmpty) {
      try {
        await db.insert(
          'settings',
          {'key': 'account.email', 'value': cleanEmail},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await db.insert(
          'settings',
          {'key': 'email', 'value': cleanEmail},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}
    }
  }

  Future<void> _clear() async {
    await db.update(
        'google_auth',
        {
          'google_id': '',
          'email': '',
          'display_name': '',
          'photo_url': '',
          'id_token': '',
          'signed_in_at': '',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = 1');
  }
}

bool isPlatformSupportingGoogleSignIn() => PlatformInfo.isMobile;
