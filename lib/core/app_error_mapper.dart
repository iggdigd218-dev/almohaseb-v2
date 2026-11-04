import 'dart:async';
import 'dart:io';

import '../data/sync/error_localization_mapper.dart';

/// المترجم الموحّد للأخطاء (Global Arabic Error Mapper):
/// يحوّل كافة الاستثناءات التقنية وأكواد HTTP و Firebase و SQLite والشبكة
/// إلى رسائل عربية واضحة وقابلة للتنفيذ للمستخدم النهائي، مع حجب أي
/// StackTrace أو أكواد برمجية خام (404 / 500 / Exceptions).
class AppErrorMapper {
  AppErrorMapper._();

  static const String notFoundMessage =
      'تعذر العثور على البيانات المطلوبة، قد تكون حُذفت أو نُقلت.';
  static const String permissionDeniedMessage =
      'ليس لديك الصلاحية لتنفيذ هذا الإجراء، يرجى مراجعة مدير النظام.';
  static const String serverErrorMessage =
      'حدث خطأ غير متوقع في الخادم، يرجى المحاولة بعد قليل.';
  static const String networkErrorMessage =
      'فشل الاتصال بالشبكة، يرجى التحقق من اتصالك بالإنترنت والمحاولة مجدداً.';
  static const String dbConstraintMessage =
      'تعذر إتمام العملية بسبب تعارض في البيانات المسجلة.';
  static const String genericErrorMessage =
      'تعذر إتمام العملية حالياً، يرجى المحاولة مرة أخرى.';

  /// تحويل أي خطأ أو استثناء إلى رسالة عربية واضحة وخالية من الأكواد الخام.
  static String toUserFriendlyMessage(dynamic error, [String? fallback]) {
    if (error == null) {
      return fallback ?? genericErrorMessage;
    }

    final raw = error.toString().trim();
    if (raw.isEmpty) {
      return fallback ?? genericErrorMessage;
    }

    final lower = raw.toLowerCase();

    // 0. خطأ عدم تطابق ساعة الهاتف مع التوقيت العالمي (Clock Skew / Handshake)
    if (lower.contains('certificate is not yet valid') ||
        lower.contains('certificate has expired') ||
        lower.contains('cert_date_invalid') ||
        lower.contains('handshake.cc')) {
      return 'تاريخ أو وقت الهاتف غير مضبوط بدقة: يرجى تفعيل «ضبط الوقت والتاريخ تلقائياً» من إعدادات الهاتف لتخطي خطأ التشفير والاتصال بأمان.';
    }

    if (error is SocketException ||
        error is TimeoutException ||
        error is HandshakeException ||
        error is TlsException) {
      return networkErrorMessage;
    }

    final upper = raw.toUpperCase();

    // 1. أخطاء الشبكة والاتصال والمهلة
    if (lower.contains('socketexception') ||
        lower.contains('timeoutexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('connection closed') ||
        lower.contains('clientexception') ||
        lower.contains('handshakeexception') ||
        lower.contains('xmlhttprequest error') ||
        upper.contains('NETWORK_ERROR') ||
        lower.contains('no address associated with hostname')) {
      return networkErrorMessage;
    }

    // 2. أخطاء مصادقة Firebase (FirebaseAuthException / REST Auth Codes)
    if (upper.contains('USER-NOT-FOUND') ||
        upper.contains('USER_NOT_FOUND') ||
        upper.contains('EMAIL_NOT_FOUND')) {
      return 'لا يوجد حساب مسجل بهذا البريد الإلكتروني.';
    }
    if (upper.contains('WRONG-PASSWORD') ||
        upper.contains('WRONG_PASSWORD') ||
        upper.contains('INVALID_PASSWORD')) {
      return 'كلمة المرور غير صحيحة، يرجى التأكد وإعادة المحاولة.';
    }
    if (upper.contains('INVALID-CREDENTIAL') ||
        upper.contains('INVALID_LOGIN_CREDENTIALS') ||
        upper.contains('INVALID_CREDENTIALS_OR_NOT_FOUND')) {
      return 'بيانات تسجيل الدخول غير صحيحة، يرجى التحقق من البريد الإلكتروني وكلمة المرور.';
    }
    if (upper.contains('TOO-MANY-REQUESTS') ||
        upper.contains('TOO_MANY_ATTEMPTS_TRY_LATER')) {
      return 'تم حظر المحاولات مؤقتاً لكثرة الطلبات، يرجى الانتظار قليلاً ثم المحاولة.';
    }
    if (upper.contains('EMAIL-ALREADY-IN-USE') ||
        upper.contains('EMAIL_EXISTS')) {
      return 'هذا البريد الإلكتروني مسجل مسبقاً، يمكنك تسجيل الدخول به مباشرة.';
    }
    if (upper.contains('INVALID-EMAIL') || upper.contains('INVALID_EMAIL')) {
      return 'صيغة البريد الإلكتروني غير صحيحة.';
    }
    if (upper.contains('WEAK-PASSWORD') || upper.contains('WEAK_PASSWORD')) {
      return 'كلمة المرور ضعيفة، يرجى اختيار كلمة مرور مكونة من 6 أحرف على الأقل.';
    }
    if (upper.contains('USER-DISABLED') || upper.contains('USER_DISABLED')) {
      return 'تم إيقاف هذا الحساب من قِبل الإدارة، يرجى التواصل مع الدعم الفني.';
    }

    // 2.5 أخطاء خدمة Google Drive والنسخ السحابي
    if (lower.contains('googledriveexception') ||
        lower.contains('drive') ||
        raw.contains('Google Drive') ||
        raw.contains('النسخة') ||
        raw.contains('النسخ') ||
        lower.contains('backup') ||
        lower.contains('insufficientpermissions')) {
      if (lower.contains('لم يتم منح') ||
          upper.contains('PERMISSION_DENIED') ||
          upper.contains('FORBIDDEN') ||
          lower.contains('unauthorized') ||
          lower.contains('scope') ||
          lower.contains('insufficient') ||
          RegExp(r'\b(401|403)\b').hasMatch(raw)) {
        return 'لم يتم منح إذن الوصول إلى مساحة Google Drive: يرجى الموافقة على منح إذن Drive عند ظهوره، أو استخدام خيار «رفع / حفظ في تطبيق Google Drive» في الأسفل.';
      }
    }

    // 3. أخطاء الصلاحيات والوصول (HTTP 401 / 403 / PermissionDenied)
    if (upper.contains('PERMISSION_DENIED') ||
        upper.contains('PERMISSION-DENIED') ||
        lower.contains('permission denied') ||
        lower.contains('unauthorized') ||
        lower.contains('forbidden') ||
        RegExp(r'\b(401|403)\b').hasMatch(raw)) {
      return permissionDeniedMessage;
    }

    // 4. أخطاء عدم العثور على البيانات (HTTP 404 / NotFound)
    if (upper.contains('NOT_FOUND') ||
        upper.contains('NOT-FOUND') ||
        lower.contains('not found') ||
        RegExp(r'\b404\b').hasMatch(raw)) {
      return notFoundMessage;
    }

    // 5. أخطاء الخادم (HTTP 500 / 502 / 503 / 504 / ServerError)
    if (upper.contains('INTERNAL_SERVER_ERROR') ||
        upper.contains('SERVER_ERROR') ||
        lower.contains('internal server error') ||
        lower.contains('bad gateway') ||
        lower.contains('service unavailable') ||
        lower.contains('gateway timeout') ||
        RegExp(r'\b(500|502|503|504)\b').hasMatch(raw)) {
      return serverErrorMessage;
    }

    // 6. أخطاء قواعد البيانات والقيود (SQLite / Database Constraints)
    if (lower.contains('sqliteexception') ||
        lower.contains('databaseexception') ||
        lower.contains('unique constraint') ||
        lower.contains('foreign key constraint') ||
        lower.contains('not null constraint') ||
        lower.contains('check constraint') ||
        lower.contains('constraint failed') ||
        lower.contains('database is locked')) {
      return dbConstraintMessage;
    }

    // 7. تمرير لمحرّك ترجمة أخطاء المزامنة إن كانت رسالة تقنية معروفة
    final mappedBySync = ErrorLocalizationMapper.map(error).arabicExplanation;
    if (mappedBySync !=
        'حدث خطأ غير متوقع أثناء معالجة البيانات، يرجى تكرار المحاولة أو إبلاغ الدعم الفني.') {
      return mappedBySync;
    }

    // 8. تنظيف البادئات البرمجية وإزالة أي StackTrace أو أكواد إنجليزية خام
    var cleaned = raw
        .replaceFirst(
          RegExp(
            r'^(Exception|StateError|FormatException|ArgumentError|UnsupportedError|Error)\s*:\s*',
            caseSensitive: false,
          ),
          '',
        )
        .split('\n')
        .first
        .trim();

    // إذا كانت الرسالة تحتوي على نص عربي واضح وخالية من آثار الـ StackTrace أو الاستثناءات الإنجليزية
    final hasArabic = RegExp(r'[\u0600-\u06FF]').hasMatch(cleaned);
    final hasRawTech = RegExp(
      r'(Exception|StackTrace|#0\s|http://|https://|statusCode|status\s*code|errno\s*=|\b404\b|\b500\b|\b502\b|\b403\b|\b401\b)',
      caseSensitive: false,
    ).hasMatch(cleaned);

    if (!hasRawTech && cleaned.isNotEmpty) {
      return cleaned;
    }

    // في حال وجود بادئة عربية متبوعة باستثناء إنجليزي (مثل: "حدث خطأ أثناء الاتصال: SocketException...")
    if (hasArabic && hasRawTech) {
      final colonIdx = cleaned.indexOf(':');
      if (colonIdx > 0) {
        final prefix = cleaned.substring(0, colonIdx).trim();
        final tail = cleaned.substring(colonIdx + 1).trim();
        final tailMapped = toUserFriendlyMessage(tail, '');
        if (tailMapped.isNotEmpty && tailMapped != genericErrorMessage) {
          return tailMapped;
        }
        if (RegExp(r'[\u0600-\u06FF]').hasMatch(prefix) &&
            !RegExp(r'[A-Za-z]{4,}').hasMatch(prefix)) {
          return '$prefix — يرجى المحاولة مرة أخرى.';
        }
      }
    }

    return fallback ?? genericErrorMessage;
  }
}
