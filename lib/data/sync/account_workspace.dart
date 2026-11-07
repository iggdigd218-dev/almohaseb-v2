// (ربط الحساب — بدون لمس هوية المؤسسة) فهرس سحابي اختياري للحساب.
//
// المبدأ بعد 3.61 (استعادة سلوك 3.55):
//   - هوية المؤسسة = معرّف مساحة محلي عشوائي (WS-XXXXXXXX) لكل تثبيت.
//     لا علاقة له بحساب Google إطلاقاً — الربط يعمل بلا إنترنت.
//   - حساب Google يُستخدم للترخيص والنسخ على Drive فقط، ويُسجَّل ربطه
//     بالمساحة الحالية في فهرس اختياري لأجل استرداد يدوي مستقبلي.
//   - انضمام الموظفين يبقى عبر QR/PIN — لا يحتاجون حساب Google.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, File, Directory;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/database.dart';
import '../../core/db_init.dart';
import '../../core/factory_reset.dart';
import '../../core/security.dart';
import 'auto_backup.dart';
import '../repository.dart';
import 'cloud_firebase_transport.dart';
import 'cloud_join.dart';
import 'recovery_packet.dart';
import 'recovery_wizard_logic.dart';
import 'workspace_recovery.dart';
import 'device_id.dart';
import 'device_registry.dart';
import 'firebase_auth_service.dart';
import 'subscription_guard.dart';
import 'workspace_service.dart';

/// نتيجة إرسال طلب استعادة كلمة المرور إلى السحابة — تُعرض للمستخدم بصدق.
class RecoveryRequestOutcome {
  const RecoveryRequestOutcome({
    this.ticketId = '',
    this.ticketSaved = false,
    this.chatNotified = false,
    this.errors = const <String>[],
  });

  final String ticketId;
  final bool ticketSaved;
  final bool chatNotified;
  final List<String> errors;

  bool get deliveredRemotely => ticketSaved || chatNotified;
  bool get fullyDelivered => ticketSaved && chatNotified;
}

/// نتيجة البحث عن منشأة عبر رقم الهاتف لاستعادة الحساب أو كلمة المرور عبر الواتساب.
class PhoneWorkspaceRecoveryResult {
  final String workspaceId;
  final String storeName;
  final String ownerEmail;
  final String phone;
  final bool isLocal;

  const PhoneWorkspaceRecoveryResult({
    required this.workspaceId,
    required this.storeName,
    required this.ownerEmail,
    required this.phone,
    this.isLocal = false,
  });
}

/// معلومات منشأة مرتبطة بحساب المستخدم (سواء كمالك أو عضو مصرح).
class WorkspaceInfo {
  final String workspaceId;
  final String storeName;
  final String businessActivity;
  final String defaultCurrency;
  final String phone;
  final String ownerEmail;
  final String role; // 'owner' | 'member'
  final bool isCurrent;

  const WorkspaceInfo({
    required this.workspaceId,
    required this.storeName,
    this.businessActivity = '',
    this.defaultCurrency = 'YER',
    this.phone = '',
    this.ownerEmail = '',
    this.role = 'owner',
    this.isCurrent = false,
  });

  Map<String, Object?> toJson() => {
        'workspaceId': workspaceId,
        'storeName': storeName,
        'businessActivity': businessActivity,
        'defaultCurrency': defaultCurrency,
        'phone': phone,
        'ownerEmail': ownerEmail,
        'role': role,
      };

  factory WorkspaceInfo.fromJson(
    Map<String, dynamic> m, {
    String fallbackId = '',
    bool isCurrent = false,
  }) {
    final wsId =
        '${m['workspaceId'] ?? m['id'] ?? m['workspace_id'] ?? fallbackId}'
            .trim();
    final name =
        '${m['storeName'] ?? m['store_name'] ?? m['businessName'] ?? m['name'] ?? ''}'
            .trim();
    return WorkspaceInfo(
      workspaceId: wsId,
      storeName: name.isEmpty ? 'منشأة ($wsId)' : name,
      businessActivity: '${m['businessActivity'] ?? ''}'.trim(),
      defaultCurrency: '${m['defaultCurrency'] ?? 'YER'}'.trim().isEmpty
          ? 'YER'
          : '${m['defaultCurrency'] ?? 'YER'}'.trim(),
      phone: '${m['phone'] ?? m['whatsapp'] ?? ''}'.trim(),
      ownerEmail: '${m['ownerEmail'] ?? m['owner_email'] ?? m['email'] ?? ''}'
          .trim()
          .toLowerCase(),
      role: '${m['role'] ?? 'owner'}'.trim().isEmpty
          ? 'owner'
          : '${m['role'] ?? 'owner'}'.trim(),
      isCurrent: isCurrent,
    );
  }
}

/// حالة نتيجة فحص معالج توجيه الحسابات في السحابة.
enum CloudWorkspaceResolutionStatus {
  /// تم العثور على منشأة سابقة مرتبطة بالحساب.
  found,

  /// تأكد عدم وجود أي منشأة مسجلة بعد اكتمال الفحص السحابي بنجاح.
  notFound,

  /// تعذر الاتصال بالخادم أو حدث خطأ شبكة.
  networkError,

  /// انتهت مهلة الاتصال بالخادم.
  timeout,
}

/// نتيجة فحص معالج توجيه الحسابات (Workspace Resolver / Auth Gate) في السحابة.
class CloudWorkspaceResolution {
  final String workspaceId;
  final String role; // 'owner' | 'member' | ''
  final String memberRoleCode;
  final Map<String, dynamic>? meta;
  final CloudWorkspaceResolutionStatus status;

  const CloudWorkspaceResolution({
    required this.workspaceId,
    this.role = 'owner',
    this.memberRoleCode = 'admin',
    this.meta,
    CloudWorkspaceResolutionStatus? status,
  }) : status = status ??
            (workspaceId != '' && workspaceId != 'default'
                ? CloudWorkspaceResolutionStatus.found
                : CloudWorkspaceResolutionStatus.notFound);

  const CloudWorkspaceResolution.notFound()
      : workspaceId = '',
        role = 'owner',
        memberRoleCode = 'admin',
        meta = null,
        status = CloudWorkspaceResolutionStatus.notFound;

  const CloudWorkspaceResolution.timeout()
      : workspaceId = '',
        role = 'owner',
        memberRoleCode = 'admin',
        meta = null,
        status = CloudWorkspaceResolutionStatus.timeout;

  const CloudWorkspaceResolution.networkError()
      : workspaceId = '',
        role = 'owner',
        memberRoleCode = 'admin',
        meta = null,
        status = CloudWorkspaceResolutionStatus.networkError;

  bool get found =>
      status == CloudWorkspaceResolutionStatus.found &&
      workspaceId.isNotEmpty &&
      workspaceId != 'default';

  bool get isNotFound =>
      status == CloudWorkspaceResolutionStatus.notFound && !found;

  bool get isNetworkOrTimeoutError =>
      status == CloudWorkspaceResolutionStatus.networkError ||
      status == CloudWorkspaceResolutionStatus.timeout;
}

/// نتيجة تبنّي/استرداد مساحة الحساب بعد تسجيل الدخول.
enum AccountLinkOutcome {
  /// (محفوظة للتوافق) استُعيدت مساحة سابقة كاملة بالبيانات.
  /// لا يُنتِجها أي مسار تلقائي بعد 3.61 — الاسترداد صار بقرار صريح.
  recovered,

  /// اكتمل ربط الحساب: جلسة محفوظة + فهرس مسجّل — **بلا أي تغيير
  /// على معرّف المساحة المحلي** (سلوك 3.55 المستعاد).
  migrated,

  /// جهاز عضو في مجموعة — لا تغيير على مساحته (يتبع مديره).
  memberUntouched,

  /// (دفعة 65) الحساب مرتبط بمساحة **أخرى**: حُظر الدمج، وأُخذت نسخة
  /// احتياطية، وفُرّغت الجداول، ونُزّلت بيانات المساحة الجديدة.
  switched,

  /// حساب بريد جديد غير عضو في المنشأة السابقة وليس له مساحة سحابية سابقة:
  /// تم عزل وتصفير بيانات المنشأة السابقة وفتح قاعدة بيانات ومساحة عمل جديدة له.
  isolatedNewWorkspace,

  /// (دفعة 65) الحساب مرتبط بمساحة أخرى لكن **لا نسخة سحابية** لتلك
  /// المساحة — لم يُفرَّغ شيء، وتعذّر إتمام التبديل.
  switchUnavailable,

  /// (دفعة 65) تعذّر إتمام التبديل **بعد** تفريغ الجداول: استُرجعت
  /// بيانات المساحة الأصلية من النسخة المحتفظ بها — **بلا فقدان بيانات**.
  switchRestored,

  /// (دفعة 65) تعذّر التبديل بعد التفريغ **وتعذّر الاسترجاع التلقائي**:
  /// البيانات الأصلية ما زالت في ملف `pre_switch_backup.nexora` داخل
  /// مجلد النسخ — يجب إبلاغ المستخدم بمكانها صراحةً.
  switchDataLost,

  /// تعذر الإكمال (شبكة/إعدادات).
  failed,
}

class AccountWorkspace {
  AccountWorkspace._();

  static String _indexPath(String base, String uid) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'accounts_index/${Uri.encodeComponent(uid)}.json';

  static String emailToKey(String email) {
    final clean = email.trim().toLowerCase();
    return sha256.convert(utf8.encode(clean)).toString();
  }

  static String _emailIndexPath(String base, String email) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'emails_index/${emailToKey(email)}.json';

  /// تطبيع رقم الهاتف مع الرمز الدولي إلى مفتاح موحّد (أرقام فقط بعد إزالة البادئة 00/+).
  static String normalizePhone(String phone) {
    var digits = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.startsWith('+')) digits = digits.substring(1);
    if (digits.startsWith('00')) digits = digits.substring(2);
    return digits;
  }

  static String phoneToKey(String phone) {
    final norm = normalizePhone(phone);
    if (norm.isEmpty) return '';
    return sha256.convert(utf8.encode('phone:$norm')).toString();
  }

  static String _phoneIndexPath(String base, String phone) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'phones_index/${phoneToKey(phone)}.json';

  /// جلب توكن المصادقة الفعّال لإرفاقه بطلبات Firebase RTDB (`?auth=`).
  static Future<String?> _ensureToken() async {
    var t = FirebaseAuthRest.cachedIdToken;
    if (t != null && t.isNotEmpty) return t;
    try {
      t = await FirebaseAuthRest.cloudIdToken();
    } catch (_) {}
    return (t != null && t.isNotEmpty) ? t : null;
  }

  static Uri _withAuth(String url, String? token) {
    final uri = Uri.parse(url);
    if (token == null || token.isEmpty) return uri;
    final q = Map<String, String>.from(uri.queryParameters)..['auth'] = token;
    return uri.replace(queryParameters: q);
  }

  static Future<http.Response> _authedGet(
    String url, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final token = await _ensureToken();
    var res = await http.get(_withAuth(url, token)).timeout(timeout);
    if (token != null && (res.statusCode == 401 || res.statusCode == 403)) {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh.isNotEmpty) {
        res = await http.get(_withAuth(url, fresh)).timeout(timeout);
      }
    }
    return res;
  }

  static Future<http.Response> _authedPut(
    String url, {
    required String body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final token = await _ensureToken();
    const headers = {'Content-Type': 'application/json'};
    var res = await http
        .put(_withAuth(url, token), headers: headers, body: body)
        .timeout(timeout);
    if (token != null && (res.statusCode == 401 || res.statusCode == 403)) {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh.isNotEmpty) {
        res = await http
            .put(_withAuth(url, fresh), headers: headers, body: body)
            .timeout(timeout);
      }
    }
    return res;
  }

  static Future<http.Response> _authedPatch(
    String url, {
    required String body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final token = await _ensureToken();
    const headers = {'Content-Type': 'application/json'};
    var res = await http
        .patch(_withAuth(url, token), headers: headers, body: body)
        .timeout(timeout);
    if (token != null && (res.statusCode == 401 || res.statusCode == 403)) {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh.isNotEmpty) {
        res = await http
            .patch(_withAuth(url, fresh), headers: headers, body: body)
            .timeout(timeout);
      }
    }
    return res;
  }

  static Future<http.Response> _authedDelete(
    String url, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final token = await _ensureToken();
    var res = await http.delete(_withAuth(url, token)).timeout(timeout);
    if (token != null && (res.statusCode == 401 || res.statusCode == 403)) {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh.isNotEmpty) {
        res = await http.delete(_withAuth(url, fresh)).timeout(timeout);
      }
    }
    return res;
  }

  /// قراءة مساحة العمل المرتبطة برقم الهاتف (مع الرمز الدولي) من الفهرس المحلي والسحابي.
  static Future<String> lookupByPhone({
    required String backendUrl,
    required String phone,
    String excludeWorkspaceId = '',
  }) async {
    final norm = normalizePhone(phone);
    if (norm.length < 7) return '';
    final cleanExclude = excludeWorkspaceId.trim();

    // 1) فحص المنشآت المحفوظة محلياً على الجهاز
    try {
      final localList = await findLocalWorkspacesOnDevice();
      for (final ws in localList) {
        final wId = ws.workspaceId.trim();
        if (wId.isEmpty || wId == 'default' || wId == cleanExclude) continue;
        final wPhone = normalizePhone(ws.phone);
        if (wPhone.isNotEmpty && wPhone == norm) {
          return wId;
        }
      }
    } catch (_) {}

    if (backendUrl.trim().isEmpty) return '';

    // 2) فحص فهرس الهواتف السحابي السريع (/workspaces/_registry/phones_index)
    try {
      final res = await _authedGet(
        _phoneIndexPath(backendUrl, norm),
        timeout: const Duration(seconds: 10),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = utf8.decode(res.bodyBytes).trim();
        if (body.isNotEmpty && body != 'null') {
          final m = jsonDecode(body);
          if (m is Map) {
            final ws = '${m['workspaceId'] ?? ''}'.trim();
            if (ws.isNotEmpty && ws != 'default' && ws != cleanExclude) {
              return ws;
            }
          }
        }
      }
    } catch (_) {}

    // (تدقيق 2026-11-04) أُلغي سحب عقدة subscriptions_index.json الكاملة —
    // فهرس phones_index الموحد (بمفتاح SHA-256) هو المرجع الوحيد للهواتف؛
    // حفاظاً على الخصوصية والباندويث.

    return '';
  }

  /// ربط رقم الهاتف بمساحة العمل مع منع تكرار الرقم لمساحة أخرى.
  static Future<bool> bindPhoneWorkspace({
    required String backendUrl,
    required String phone,
    required String workspaceId,
    String email = '',
    String passwordHash = '',
  }) async {
    final norm = normalizePhone(phone);
    if (norm.length < 7 || workspaceId.isEmpty || workspaceId == 'default') {
      return false;
    }
    try {
      final existingWs = await lookupByPhone(
        backendUrl: backendUrl,
        phone: norm,
        excludeWorkspaceId: workspaceId,
      );
      if (existingWs.isNotEmpty && existingWs != workspaceId) {
        // رقم الهاتف مسجّل مسبقاً لمساحة أخرى — يمنع التكرار منعاً باتاً.
        return false;
      }
      await _authedPatch(
        _phoneIndexPath(backendUrl, norm),
        body: jsonEncode({
          'workspaceId': workspaceId,
          'phone': norm,
          if (email.trim().isNotEmpty) 'email': email.trim().toLowerCase(),
          if (passwordHash.trim().isNotEmpty)
            'password_hash': passwordHash.trim(),
          'updated_at': {'.sv': 'timestamp'},
        }),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// توليد قائمة صيغ رقم الهاتف المحتملة (مع رمز الدولة وبدونه) للبحث المرن في الفهرس.
  static List<String> _phoneRecoveryCandidates(
    String rawPhone, {
    String countryDialCode = '+967',
  }) {
    final normInput = normalizePhone(rawPhone);
    if (normInput.length < 7) return const [];
    final dialDigits = normalizePhone(countryDialCode);
    final set = <String>{normInput};
    var localDigits = normInput;
    if (dialDigits.isNotEmpty && localDigits.startsWith(dialDigits)) {
      localDigits = localDigits.substring(dialDigits.length);
    }
    if (localDigits.startsWith('0')) {
      localDigits = localDigits.substring(1);
    }
    if (localDigits.length >= 7) {
      if (dialDigits.isNotEmpty) {
        set.add('$dialDigits$localDigits');
      }
      set.add(localDigits);
      set.add('0$localDigits');
      // دعم رموز الدول العربية الشائعة في حال لم يغير المستخدم الرمز الافتراضي
      for (final code in const ['967', '966', '971', '968', '965', '20']) {
        set.add('$code$localDigits');
      }
    }
    return set.toList();
  }

  /// البحث عن المنشأة المرتبطة برقم الهاتف (محلياً وسحابياً) لاستعادة الحساب وكلمة المرور عبر الواتساب.
  static Future<PhoneWorkspaceRecoveryResult?> lookupWorkspaceByPhoneForRecovery({
    required String backendUrl,
    required String phone,
    String countryDialCode = '+967',
  }) async {
    final candidates = _phoneRecoveryCandidates(
      phone,
      countryDialCode: countryDialCode,
    );
    if (candidates.isEmpty) return null;

    // 1) فحص المنشآت المحفوظة محلياً على هذا الجهاز
    try {
      final localList = await findLocalWorkspacesOnDevice();
      for (final ws in localList) {
        final wId = ws.workspaceId.trim();
        if (wId.isEmpty || wId == 'default') continue;
        final wPhone = normalizePhone(ws.phone);
        if (wPhone.length < 7) continue;
        final matched = candidates.any(
          (c) =>
              wPhone == c ||
              (c.length >= 8 && wPhone.endsWith(c)) ||
              (wPhone.length >= 8 && c.endsWith(wPhone)),
        );
        if (matched) {
          return PhoneWorkspaceRecoveryResult(
            workspaceId: wId,
            storeName: ws.storeName.isNotEmpty ? ws.storeName : 'منشأتي ($wId)',
            ownerEmail: ws.ownerEmail,
            phone: ws.phone.isNotEmpty ? ws.phone : candidates.first,
            isLocal: true,
          );
        }
      }
    } catch (_) {}

    final root = _trimSlashes(backendUrl);
    if (root.isEmpty) return null;

    // 2) فحص فهرس الهواتف السحابي (/workspaces/_registry/phones_index) لجميع الصيغ المحتملة
    for (final cand in candidates) {
      try {
        final res = await _authedGet(
          _phoneIndexPath(root, cand),
          timeout: const Duration(seconds: 8),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              final wsId =
                  '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
              if (wsId.isNotEmpty && wsId != 'default') {
                var email =
                    '${m['email'] ?? m['owner_email'] ?? m['ownerEmail'] ?? ''}'
                        .trim()
                        .toLowerCase();
                var storeName =
                    '${m['storeName'] ?? m['store_name'] ?? m['businessName'] ?? ''}'
                        .trim();
                var storedPhone = '${m['phone'] ?? cand}'.trim();

                // جلب تفاصيل المنشأة من عقدة meta.json لاستكمال الاسم والبريد الإلكتروني
                try {
                  final metaRes = await _authedGet(
                    '$root/workspaces/${Uri.encodeComponent(wsId)}/meta.json',
                    timeout: const Duration(seconds: 7),
                  );
                  if (metaRes.statusCode >= 200 && metaRes.statusCode < 300) {
                    final metaBody = utf8.decode(metaRes.bodyBytes).trim();
                    if (metaBody.isNotEmpty && metaBody != 'null') {
                      final metaMap = jsonDecode(metaBody);
                      if (metaMap is Map) {
                        if (storeName.isEmpty) {
                          storeName =
                              '${metaMap['storeName'] ?? metaMap['store_name'] ?? metaMap['businessName'] ?? metaMap['name'] ?? ''}'
                                  .trim();
                        }
                        if (email.isEmpty) {
                          email =
                              '${metaMap['owner_email'] ?? metaMap['ownerEmail'] ?? metaMap['email'] ?? ''}'
                                  .trim()
                                  .toLowerCase();
                        }
                        final mp =
                            '${metaMap['phone'] ?? metaMap['whatsapp'] ?? ''}'
                                .trim();
                        if (mp.isNotEmpty) storedPhone = mp;
                      }
                    }
                  }
                } catch (_) {}

                return PhoneWorkspaceRecoveryResult(
                  workspaceId: wsId,
                  storeName:
                      storeName.isNotEmpty ? storeName : 'منشأة ($wsId)',
                  ownerEmail: email,
                  phone: storedPhone.isNotEmpty ? storedPhone : cand,
                  isLocal: false,
                );
              }
            }
          }
        }
      } catch (_) {}
    }

    return null;
  }

  /// (R-01/R-02) الحزمة تُبنى وتُوقَّع الآن عبر `RecoveryPacket` — مصدر حقيقة
  /// واحد يتشاركه تطبيق الإدارة، بتوقيع HMAC-SHA256. لا توقيع بلا سرّ، ولا
  /// مفاتيح مظروف مختلفة بين المرسل والمستقبل.
  static String buildEncryptedAiRecoveryPacket({
    required String deviceId,
    required String hardwareFingerprint,
    required String phone,
    String email = '',
    String workspaceId = '',
    String storeName = '',
  }) {
    final normPhone = normalizePhone(phone);
    final packet = RecoveryPacket.build(
      phone: normPhone,
      phoneKey: phoneToKey(normPhone),
      deviceId: deviceId,
      deviceFingerprint: hardwareFingerprint,
      email: email,
      workspaceId: workspaceId,
      storeName: storeName,
    );
    lastRecoveryPacket = packet;
    return packet.encode();
  }

  /// آخر حزمة بُنيت على هذا الجهاز (للاختبارات والتشخيص فقط).
  static RecoveryPacket? lastRecoveryPacket;

  /// (R-06) نتيجة إرسال طلب الاستعادة — تُعرض للمستخدم كما هي بدل ادعاء نجاح.
  static Future<RecoveryRequestOutcome> submitPasswordResetSupportRequest({
    required String backendUrl,
    required String workspaceId,
    required String deviceId,
    required String phone,
    String email = '',
    String storeName = '',
    required String aiPacketCode,
  }) async {
    final root = _trimSlashes(backendUrl);
    if (root.isEmpty) {
      return const RecoveryRequestOutcome(
        errors: ['لا يوجد رابط سحابي مُهيّأ على هذا الجهاز — أرسل الحزمة عبر الواتساب.'],
      );
    }
    final errors = <String>[];
    var ticketSaved = false;
    var chatNotified = false;

    final cleanWs =
        workspaceId.trim().isNotEmpty && workspaceId.trim() != 'default'
            ? workspaceId.trim()
            : 'RECOVERY_${phoneToKey(phone).substring(0, 12)}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final ticketId = 'PRQ-$now';
    final encWs = Uri.encodeComponent(cleanWs);

    // 1) تذكرة رسمية (سجل دائم لكل طلب، بمفتاح فريد لكل محاولة).
    try {
      final res = await _authedPatch(
        '$root/workspaces/_registry/password_reset_requests/$encWs/$ticketId.json',
        body: jsonEncode({
          'ticket_id': ticketId,
          'workspaceId': cleanWs,
          'deviceId': deviceId.trim(),
          'phone_index_key': phoneToKey(phone),
          if (email.trim().isNotEmpty) 'email': email.trim().toLowerCase(),
          if (storeName.trim().isNotEmpty) 'storeName': storeName.trim(),
          'ai_packet': aiPacketCode,
          'status': 'pending_admin_approval',
          'created_at': now,
          'updated_at': {'.sv': 'timestamp'},
        }),
      );
      ticketSaved = res.statusCode >= 200 && res.statusCode < 300;
      if (!ticketSaved) {
        errors.add('تذكرة الطلب لم تُسجَّل (HTTP ${res.statusCode}).');
      }
    } catch (e) {
      errors.add('تذكرة الطلب لم تُسجَّل (${_briefError(e)}).');
    }

    // 2) إشعار صندوق الدعم ليظهر الطلب للمشرف.
    try {
      final res = await _authedPut(
        '$root/support_chats/$encWs/messages/$ticketId.json',
        body: jsonEncode({
          'id': ticketId,
          'sender': 'client',
          'type': 'ai_password_recovery_rpc',
          'text': aiPacketCode,
          'timestamp': now,
        }),
      );
      chatNotified = res.statusCode >= 200 && res.statusCode < 300;
      if (chatNotified) {
        try {
          await _authedPatch(
            '$root/support_chats/$encWs/meta.json',
            body: jsonEncode({
              'workspaceId': cleanWs,
              'storeName':
                  storeName.trim().isNotEmpty ? storeName.trim() : cleanWs,
              'unread_by_admin': true,
              'unreadByAdmin': true,
              'last_message': '[NEXORA_AI_CORE_RPC :: 0x7F_AUTH_RESET]',
              'updated_at': now,
            }),
          );
        } catch (e) {
          errors.add('تعذّر تحديث عنوان صندوق الدعم (${_briefError(e)}).');
        }
      } else {
        errors.add('رسالة الدعم لم تُسجَّل (HTTP ${res.statusCode}).');
      }
    } catch (e) {
      errors.add('رسالة الدعم لم تُسجَّل (${_briefError(e)}).');
    }

    return RecoveryRequestOutcome(
      ticketId: ticketId,
      ticketSaved: ticketSaved,
      chatNotified: chatNotified,
      errors: List<String>.unmodifiable(errors),
    );
  }

  /// (R-05) تحقّق **قراءة فقط** من بصمة كلمة المرور المعتمدة إداريًا.
  ///
  /// لا يكتب هذا المسار أي شيء على السحابة إطلاقًا: يقرأ فهرس البريد/الهاتف
  /// ثم `meta.json` ويقارن البصمة محليًا. يُستخدم كمسار رديف **فقط** عند فشل
  /// الدخول عبر Firebase Auth، حتى يستطيع المالك الدخول بالكلمة التي عيّنها
  /// المشرف عبر `adminUpdateWorkspacePassword`.
  static Future<PhoneWorkspaceRecoveryResult?> verifyWorkspacePasswordInCloud({
    required String backendUrl,
    required String emailOrPhone,
    required String password,
    String countryDialCode = '+967',
  }) async {
    final root = _trimSlashes(backendUrl);
    final cleanInput = emailOrPhone.trim();
    final cleanPass = password.trim();
    if (root.isEmpty || cleanInput.isEmpty || cleanPass.length < 4) {
      return null;
    }

    String wsId = '';
    String ownerEmail = '';
    String storeName = '';
    String resolvedPhone = '';
    String storedHash = '';

    if (cleanInput.contains('@')) {
      ownerEmail = cleanInput.toLowerCase();
      try {
        final res = await _authedGet(
          _emailIndexPath(root, ownerEmail),
          timeout: const Duration(seconds: 7),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              wsId = '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
              storeName = '${m['storeName'] ?? m['store_name'] ?? ''}'.trim();
              resolvedPhone = '${m['phone'] ?? ''}'.trim();
              storedHash = '${m['password_hash'] ?? ''}'.trim();
            }
          }
        }
      } catch (_) {}
    } else {
      final phoneLookup = await lookupWorkspaceByPhoneForRecovery(
        backendUrl: root,
        phone: cleanInput,
        countryDialCode: countryDialCode,
      );
      if (phoneLookup != null) {
        wsId = phoneLookup.workspaceId;
        ownerEmail = phoneLookup.ownerEmail;
        storeName = phoneLookup.storeName;
        resolvedPhone = phoneLookup.phone;
      }
    }

    if (wsId.isEmpty || wsId == 'default') return null;

    try {
      final metaRes = await _authedGet(
        '$root/workspaces/${Uri.encodeComponent(wsId)}/meta.json',
        timeout: const Duration(seconds: 7),
      );
      if (metaRes.statusCode >= 200 && metaRes.statusCode < 300) {
        final metaBody = utf8.decode(metaRes.bodyBytes).trim();
        if (metaBody.isNotEmpty && metaBody != 'null') {
          final metaMap = jsonDecode(metaBody);
          if (metaMap is Map) {
            final mh = '${metaMap['password_hash'] ?? ''}'.trim();
            if (mh.isNotEmpty) storedHash = mh;
            if (storeName.isEmpty) {
              storeName =
                  '${metaMap['storeName'] ?? metaMap['store_name'] ?? metaMap['businessName'] ?? metaMap['name'] ?? ''}'
                      .trim();
            }
            if (ownerEmail.isEmpty) {
              ownerEmail = '${metaMap['owner_email'] ?? metaMap['ownerEmail'] ?? metaMap['email'] ?? ''}'
                  .trim()
                  .toLowerCase();
            }
            if (resolvedPhone.isEmpty) {
              resolvedPhone =
                  '${metaMap['phone'] ?? metaMap['whatsapp'] ?? ''}'.trim();
            }
          }
        }
      }
    } catch (_) {}

    if (storedHash.isEmpty) return null;
    if (!Security.verify(cleanPass, storedHash)) return null;

    return PhoneWorkspaceRecoveryResult(
      workspaceId: wsId,
      storeName: storeName.isNotEmpty ? storeName : 'منشأة ($wsId)',
      ownerEmail: ownerEmail,
      phone: resolvedPhone,
      isLocal: false,
    );
  }

  // ────────────────────── هوية الهاتف (بديل البريد) ──────────────────────

  /// بريد داخلي معياري لحساب أُنشئ برقم الهاتف فقط.
  static String internalEmailForPhone(String phone) {
    final digits = normalizePhone(phone).replaceAll(RegExp(r'[^0-9]'), '');
    return 'u_$digits@almohaseb.local';
  }

  /// هل البريد داخلي (مُولَّد من رقم هاتف)؟
  static bool isInternalPhoneEmail(String email) =>
      email.trim().toLowerCase().endsWith('@almohaseb.local');

  /// هل المعرّف المدخل بريد إلكتروني (وإلا فهو رقم هاتف)؟
  static bool looksLikeEmail(String input) => input.contains('@');

  /// تحويل ما يكتبه المستخدم في خانة المعرّف إلى بريد صالح لمصادقة Firebase.
  static String authEmailForIdentifier(String input) {
    final clean = input.trim();
    if (looksLikeEmail(clean)) return clean.toLowerCase();
    return internalEmailForPhone(clean);
  }

  // ────────────────────── معالج الاستعادة متعدد الصفحات ──────────────────────

  /// (الخطوة 1) هل توجد منشأة لهذا المعرّف؟ وماذا نعرف عنها؟
  /// لا يكشف أي بصمة كلمات مرور — فقط بيانات تعريفية عامة.
  static Future<RecoveryTargetSnapshot> resolveRecoveryTarget({
    required String backendUrl,
    required String identifier,
    String countryDialCode = '+967',
  }) async {
    final root = _trimSlashes(backendUrl);
    final clean = identifier.trim();
    if (root.isEmpty || clean.isEmpty) return RecoveryTargetSnapshot.missing;

    String wsId = '';
    String ownerEmail = '';
    String storeName = '';
    String phone = '';

    if (looksLikeEmail(clean)) {
      ownerEmail = clean.toLowerCase();
      try {
        final res = await _authedGet(
          _emailIndexPath(root, ownerEmail),
          timeout: const Duration(seconds: 7),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              wsId = '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
              storeName = '${m['storeName'] ?? m['store_name'] ?? ''}'.trim();
              phone = '${m['phone'] ?? ''}'.trim();
            }
          }
        }
      } catch (_) {}
    } else {
      final found = await lookupWorkspaceByPhoneForRecovery(
        backendUrl: root,
        phone: clean,
        countryDialCode: countryDialCode,
      );
      if (found != null) {
        wsId = found.workspaceId;
        storeName = found.storeName;
        phone = found.phone;
        ownerEmail = found.ownerEmail;
      }
    }

    if (wsId.isEmpty || wsId == 'default') return RecoveryTargetSnapshot.missing;

    var activity = '';
    try {
      final metaRes = await _authedGet(
        '$root/workspaces/${Uri.encodeComponent(wsId)}/meta.json',
        timeout: const Duration(seconds: 7),
      );
      if (metaRes.statusCode >= 200 && metaRes.statusCode < 300) {
        final metaBody = utf8.decode(metaRes.bodyBytes).trim();
        if (metaBody.isNotEmpty && metaBody != 'null') {
          final m = jsonDecode(metaBody);
          if (m is Map) {
            if (storeName.isEmpty) {
              storeName = '${m['storeName'] ?? m['store_name'] ?? m['businessName'] ?? m['name'] ?? ''}'.trim();
            }
            activity = '${m['businessActivity'] ?? m['activity'] ?? ''}'.trim();
            if (phone.isEmpty) {
              phone = '${m['phone'] ?? m['whatsapp'] ?? ''}'.trim();
            }
            if (ownerEmail.isEmpty) {
              ownerEmail = '${m['owner_email'] ?? m['ownerEmail'] ?? ''}'.trim().toLowerCase();
            }
          }
        }
      }
    } catch (_) {}

    return RecoveryTargetSnapshot(
      workspaceId: wsId,
      storeName: storeName,
      activity: activity,
      phone: phone,
      ownerEmail: ownerEmail,
    );
  }

  /// (الخطوة 2) هل الكلمة «المتذكَّرة» تطابق بصمة حالية أو سابقة؟
  /// يرجع 1.0 للتطابق التام، 0.75 للتطابق مع سجل سابق، 0 لعدم التطابق.
  static Future<double> passwordRecallScore({
    required String backendUrl,
    required String workspaceId,
    required String candidate,
  }) async {
    final root = _trimSlashes(backendUrl);
    final pass = candidate.trim();
    if (root.isEmpty || workspaceId.trim().isEmpty || pass.isEmpty) return 0;
    try {
      final res = await _authedGet(
        '$root/workspaces/${Uri.encodeComponent(workspaceId)}/meta.json',
        timeout: const Duration(seconds: 7),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return 0;
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.isEmpty || body == 'null') return 0;
      final meta = jsonDecode(body);
      if (meta is! Map) return 0;

      final current = '${meta['password_hash'] ?? ''}'.trim();
      if (current.isNotEmpty && Security.verify(pass, current)) return 1.0;

      final history = meta['password_history'];
      if (history is Map) {
        for (final v in history.values) {
          final h = '${(v is Map ? (v['hash'] ?? '') : v)}'.trim();
          if (h.isNotEmpty && Security.verify(pass, h)) return 0.75;
        }
      } else if (history is List) {
        for (final v in history) {
          final h = '${(v is Map ? (v['hash'] ?? '') : v)}'.trim();
          if (h.isNotEmpty && Security.verify(pass, h)) return 0.75;
        }
      }
    } catch (_) {}
    return 0;
  }

  /// (الخطوة 4) حفظ كلمة المرور الجديدة **بعد** اجتياز المعالج.
  ///
  /// يُستدعى فقط من المعالج بعد `RecoveryAssessment.passed == true`، أو من
  /// مسار المشرف في تطبيق الإدارة. يكتب: بصمة جديدة + سجل البصمة السابقة +
  /// الفهارس + سجل أمني في المنشأة.
  static Future<bool> applyRecoveredPassword({
    required String backendUrl,
    required String workspaceId,
    required String newPassword,
    double confidenceScore = 0,
    String deviceId = '',
    String phone = '',
    String email = '',
  }) async {
    final root = _trimSlashes(backendUrl);
    final cleanWs = workspaceId.trim();
    final cleanPass = newPassword.trim();
    if (root.isEmpty || cleanWs.isEmpty || cleanWs == 'default') return false;
    if (cleanPass.length < 6) return false;

    final now = DateTime.now().millisecondsSinceEpoch;
    final pwHash = Security.hash(cleanPass);
    var saved = false;

    // 1) بصمة جديدة + نقل البصمة القديمة إلى السجل (يتيح «الكلمة المتذكَّرة»).
    try {
      String oldHash = '';
      try {
        final metaRes = await _authedGet(
          '$root/workspaces/${Uri.encodeComponent(cleanWs)}/meta.json',
          timeout: const Duration(seconds: 7),
        );
        if (metaRes.statusCode >= 200 && metaRes.statusCode < 300) {
          final m = jsonDecode(utf8.decode(metaRes.bodyBytes).trim());
          if (m is Map) oldHash = '${m['password_hash'] ?? ''}'.trim();
        }
      } catch (_) {}

      final res = await _authedPatch(
        '$root/workspaces/${Uri.encodeComponent(cleanWs)}/meta.json',
        body: jsonEncode({
          'password_hash': pwHash,
          'password_updated_at': now,
          'password_updated_by': 'recovery_wizard',
          if (oldHash.isNotEmpty)
            'password_history/${now ~/ 1000}': {
              'hash': oldHash,
              'replaced_at': now,
            },
          'updated_at': {'.sv': 'timestamp'},
        }),
      );
      saved = res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {}

    if (!saved) return false;

    // 2) الفهارس (بريد/هاتف) لتظل الوجهة معروفة للتسجيل لاحقًا.
    final cleanEmail = email.trim().toLowerCase();
    final cleanPhone = normalizePhone(phone);
    if (cleanEmail.isNotEmpty && cleanEmail.contains('@')) {
      try {
        await _authedPatch(
          _emailIndexPath(root, cleanEmail),
          body: jsonEncode({
            'workspaceId': cleanWs,
            'email': cleanEmail,
            'password_hash': pwHash,
            'updated_at': {'.sv': 'timestamp'},
          }),
        );
      } catch (_) {}
    }
    if (cleanPhone.replaceAll(RegExp(r'[^0-9]'), '').length >= 7) {
      try {
        await _authedPatch(
          _phoneIndexPath(root, cleanPhone),
          body: jsonEncode({
            'workspaceId': cleanWs,
            'phone': cleanPhone,
            if (cleanEmail.isNotEmpty) 'email': cleanEmail,
            'password_hash': pwHash,
            'updated_at': {'.sv': 'timestamp'},
          }),
        );
      } catch (_) {}
    }

    // 3) سجل أمني دائم (من فعل ماذا ومتى وبأي درجة موثوقية).
    try {
      await _authedPut(
        '$root/workspaces/${Uri.encodeComponent(cleanWs)}/security_log/$now.json',
        body: jsonEncode({
          'action': 'password_recovered_by_wizard',
          'confidence_score': confidenceScore,
          'device_id': deviceId.trim(),
          'at': now,
        }),
      );
    } catch (_) {}

    return true;
  }

  static String _briefError(Object e) {
    final s = '$e'.replaceAll('\n', ' ').trim();
    return s.length <= 90 ? s : '${s.substring(0, 90)}…';
  }

  static String _trimSlashes(String url) {
    var out = url.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// فحص متوازٍ وسريع (O(1)) في Firebase Realtime Database لتحديد مساحة العمل المرتبطة بالحساب
  /// بسقف زمني كلي لا يتعدى 8 ثوانٍ (دون أي تنزيل شامل لشجرة `/workspaces.json`):
  ///   1) فهرس البريد (`/workspaces/_registry/emails_index/{emailKey}`)
  ///   2) فهرس منشآت المستخدم (`/workspaces/_registry/user_workspaces/{emailKey}`)
  ///   3) فهرس الحساب المباشر (`/workspaces/_registry/accounts_index/{uid}`)
  ///   4) فهرس التجربة والاشتراك المرتبط بـ UID (`/trials/{uidFp}`)
  static Future<CloudWorkspaceResolution> resolveWorkspaceInCloud({
    required String backendUrl,
    required String email,
    String uid = '',
    String deviceId = '',
    String deviceFingerprint = '',
    String phone = '',
  }) async {
    final clean = email.trim().toLowerCase();
    final cleanUid = uid.trim();
    final cleanDev = deviceId.trim();
    final cleanFp = deviceFingerprint.trim();
    final cleanPhone = phone.replaceAll(RegExp(r'[^\d]'), '');

    if (clean.isEmpty &&
        cleanUid.isEmpty &&
        cleanDev.isEmpty &&
        cleanFp.isEmpty &&
        cleanPhone.isEmpty) {
      return const CloudWorkspaceResolution.notFound();
    }
    final root = _trimSlashes(backendUrl);
    if (root.isEmpty) {
      return const CloudWorkspaceResolution.notFound();
    }

    var anyHttpOk = false;
    var anyTimeout = false;
    var anyNetworkError = false;

    Future<CloudWorkspaceResolution?> checkEmailsIndex() async {
      if (clean.isEmpty) return null;
      try {
        final res = await _authedGet(
          _emailIndexPath(backendUrl, clean),
          timeout: const Duration(seconds: 7),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          anyHttpOk = true;
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              final ws = '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
              if (ws.isNotEmpty && ws != 'default') {
                final role = '${m['role'] ?? 'owner'}'.trim();
                final roleCode =
                    '${m['role_code'] ?? m['roleCode'] ?? (role == 'member' ? 'cashier' : 'admin')}'
                        .trim();
                return CloudWorkspaceResolution(
                  workspaceId: ws,
                  role: role.isEmpty ? 'owner' : role,
                  memberRoleCode: roleCode.isEmpty ? 'admin' : roleCode,
                  meta: Map<String, dynamic>.from(m),
                  status: CloudWorkspaceResolutionStatus.found,
                );
              }
            }
          }
        } else {
          anyNetworkError = true;
        }
      } on TimeoutException {
        anyTimeout = true;
      } catch (_) {
        anyNetworkError = true;
      }
      return null;
    }

    Future<CloudWorkspaceResolution?> checkUserWorkspaces() async {
      if (clean.isEmpty) return null;
      try {
        final uwRes = await _authedGet(
          '$root/workspaces/_registry/user_workspaces/${emailToKey(clean)}.json',
          timeout: const Duration(seconds: 7),
        );
        if (uwRes.statusCode >= 200 && uwRes.statusCode < 300) {
          anyHttpOk = true;
          final uwBody = utf8.decode(uwRes.bodyBytes).trim();
          if (uwBody.isNotEmpty && uwBody != 'null') {
            final uwMap = jsonDecode(uwBody);
            if (uwMap is Map) {
              for (final entry in uwMap.entries) {
                final v = entry.value;
                final ws = v is Map
                    ? '${v['workspaceId'] ?? v['workspace_id'] ?? entry.key}'
                        .trim()
                    : '${entry.key}'.trim();
                if (ws.isNotEmpty && ws != 'default') {
                  final role =
                      v is Map ? '${v['role'] ?? 'owner'}'.trim() : 'owner';
                  final roleCode = v is Map
                      ? '${v['role_code'] ?? v['roleCode'] ?? (role == 'member' ? 'cashier' : 'admin')}'
                          .trim()
                      : 'admin';
                  return CloudWorkspaceResolution(
                    workspaceId: ws,
                    role: role.isEmpty ? 'owner' : role,
                    memberRoleCode: roleCode.isEmpty ? 'admin' : roleCode,
                    meta: v is Map ? Map<String, dynamic>.from(v) : null,
                    status: CloudWorkspaceResolutionStatus.found,
                  );
                }
              }
            }
          }
        } else {
          anyNetworkError = true;
        }
      } on TimeoutException {
        anyTimeout = true;
      } catch (_) {
        anyNetworkError = true;
      }
      return null;
    }

    Future<CloudWorkspaceResolution?> checkAccountsIndexByUid() async {
      if (cleanUid.isEmpty) return null;
      try {
        final res = await _authedGet(
          _indexPath(backendUrl, cleanUid),
          timeout: const Duration(seconds: 7),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          anyHttpOk = true;
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              final ws = '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
              if (ws.isNotEmpty && ws != 'default') {
                final role = '${m['role'] ?? 'owner'}'.trim();
                return CloudWorkspaceResolution(
                  workspaceId: ws,
                  role: role.isEmpty ? 'owner' : role,
                  meta: Map<String, dynamic>.from(m),
                  status: CloudWorkspaceResolutionStatus.found,
                );
              }
            }
          }
        } else {
          anyNetworkError = true;
        }
      } on TimeoutException {
        anyTimeout = true;
      } catch (_) {
        anyNetworkError = true;
      }
      return null;
    }

    Future<CloudWorkspaceResolution?> checkTrialsByUid() async {
      if (cleanUid.isEmpty) return null;
      try {
        final uidFp = SubscriptionGuard.fingerprintHash('uid:$cleanUid');
        final trRes = await _authedGet(
          '$root/trials/$uidFp.json',
          timeout: const Duration(seconds: 7),
        );
        if (trRes.statusCode >= 200 && trRes.statusCode < 300) {
          anyHttpOk = true;
          final trBody = utf8.decode(trRes.bodyBytes).trim();
          if (trBody.isNotEmpty && trBody != 'null') {
            final trMap = jsonDecode(trBody);
            if (trMap is Map) {
              final ws =
                  '${trMap['workspace_id'] ?? trMap['workspaceId'] ?? ''}'
                      .trim();
              final trEmail =
                  '${trMap['owner_email'] ?? trMap['email'] ?? ''}'
                      .trim()
                      .toLowerCase();
              if (ws.isNotEmpty &&
                  ws != 'default' &&
                  (trEmail.isEmpty || clean.isEmpty || trEmail == clean)) {
                return CloudWorkspaceResolution(
                  workspaceId: ws,
                  role: 'owner',
                  meta: Map<String, dynamic>.from(trMap),
                  status: CloudWorkspaceResolutionStatus.found,
                );
              }
            }
          }
        } else {
          anyNetworkError = true;
        }
      } on TimeoutException {
        anyTimeout = true;
      } catch (_) {
        anyNetworkError = true;
      }
      return null;
    }

    Future<CloudWorkspaceResolution?> checkDeviceIndexById() async {
      if (cleanDev.isEmpty) return null;
      try {
        final res = await _authedGet(
          '$root/workspaces/_registry/device_index/$cleanDev.json',
          timeout: const Duration(seconds: 7),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          anyHttpOk = true;
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              final ws =
                  '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
              if (ws.isNotEmpty && ws != 'default') {
                final role = '${m['role'] ?? 'owner'}'.trim();
                final roleCode =
                    '${m['role_code'] ?? m['roleCode'] ?? (role == 'member' ? 'cashier' : 'admin')}'
                        .trim();
                return CloudWorkspaceResolution(
                  workspaceId: ws,
                  role: role.isEmpty ? 'owner' : role,
                  memberRoleCode: roleCode.isEmpty ? 'admin' : roleCode,
                  meta: Map<String, dynamic>.from(m),
                  status: CloudWorkspaceResolutionStatus.found,
                );
              }
            }
          }
        } else {
          anyNetworkError = true;
        }
      } on TimeoutException {
        anyTimeout = true;
      } catch (_) {
        anyNetworkError = true;
      }
      return null;
    }

    Future<CloudWorkspaceResolution?> checkDeviceIndexByFingerprint() async {
      if (cleanFp.isEmpty) return null;
      try {
        final res = await _authedGet(
          '$root/workspaces/_registry/device_index/$cleanFp.json',
          timeout: const Duration(seconds: 7),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          anyHttpOk = true;
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              final ws =
                  '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
              if (ws.isNotEmpty && ws != 'default') {
                final role = '${m['role'] ?? 'owner'}'.trim();
                final roleCode =
                    '${m['role_code'] ?? m['roleCode'] ?? (role == 'member' ? 'cashier' : 'admin')}'
                        .trim();
                return CloudWorkspaceResolution(
                  workspaceId: ws,
                  role: role.isEmpty ? 'owner' : role,
                  memberRoleCode: roleCode.isEmpty ? 'admin' : roleCode,
                  meta: Map<String, dynamic>.from(m),
                  status: CloudWorkspaceResolutionStatus.found,
                );
              }
            }
          }
        } else {
          anyNetworkError = true;
        }
      } on TimeoutException {
        anyTimeout = true;
      } catch (_) {
        anyNetworkError = true;
      }
      return null;
    }

    Future<CloudWorkspaceResolution?> checkTrialsByFingerprint() async {
      if (cleanFp.isEmpty) return null;
      try {
        final res = await _authedGet(
          '$root/trials/$cleanFp.json',
          timeout: const Duration(seconds: 7),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          anyHttpOk = true;
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              final ws =
                  '${m['workspace_id'] ?? m['workspaceId'] ?? ''}'.trim();
              if (ws.isNotEmpty && ws != 'default') {
                return CloudWorkspaceResolution(
                  workspaceId: ws,
                  role: 'owner',
                  meta: Map<String, dynamic>.from(m),
                  status: CloudWorkspaceResolutionStatus.found,
                );
              }
            }
          }
        } else {
          anyNetworkError = true;
        }
      } on TimeoutException {
        anyTimeout = true;
      } catch (_) {
        anyNetworkError = true;
      }
      return null;
    }

    Future<CloudWorkspaceResolution?> checkPhonesIndex() async {
      if (cleanPhone.length < 7) return null;
      // (تدقيق 2026-11-04) الاتحاد مع مسار الفهرس الفعلي: bindPhoneWorkspace
      // يحفظ الرقم بمفتاح SHA-256 عبر _phoneIndexPath — البحث بالرقم الخام
      // كان يفوّت كل روابط الهواتف القائمة في السحابة.
      try {
        final res = await _authedGet(
          _phoneIndexPath(root, cleanPhone),
          timeout: const Duration(seconds: 7),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          anyHttpOk = true;
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty && body != 'null') {
            final m = jsonDecode(body);
            if (m is Map) {
              final ws =
                  '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
              if (ws.isNotEmpty && ws != 'default') {
                return CloudWorkspaceResolution(
                  workspaceId: ws,
                  role: 'owner',
                  meta: Map<String, dynamic>.from(m),
                  status: CloudWorkspaceResolutionStatus.found,
                );
              }
            }
          }
        }
      } catch (_) {}
      return null;
    }

    try {
      final results = await Future.wait<CloudWorkspaceResolution?>([
        checkEmailsIndex(),
        checkUserWorkspaces(),
        checkAccountsIndexByUid(),
        checkTrialsByUid(),
        checkDeviceIndexById(),
        checkDeviceIndexByFingerprint(),
        checkTrialsByFingerprint(),
        checkPhonesIndex(),
      ]).timeout(const Duration(seconds: 10));

      final foundList = results.whereType<CloudWorkspaceResolution>().where((r) => r.found).toList();

      if (foundList.isNotEmpty) {
        // نرجّح دائماً المنشآت النشطة/المدفوعة (active / enterprise) على المنشآت التجريبية
        final activeMatch = foundList.firstWhere(
          (r) {
            final st = '${r.meta?['status'] ?? r.meta?['subscriptionStatus'] ?? ''}'.trim().toLowerCase();
            final plan = '${r.meta?['plan_type'] ?? r.meta?['planType'] ?? ''}'.trim().toLowerCase();
            return st == 'active' || plan == 'enterprise';
          },
          orElse: () => foundList.first,
        );
        return activeMatch;
      }
    } on TimeoutException {
      return const CloudWorkspaceResolution.timeout();
    } catch (_) {
      return const CloudWorkspaceResolution.networkError();
    }

    if (anyHttpOk) {
      return const CloudWorkspaceResolution.notFound();
    }
    if (anyTimeout) {
      return const CloudWorkspaceResolution.timeout();
    }
    if (anyNetworkError) {
      return const CloudWorkspaceResolution.networkError();
    }
    return const CloudWorkspaceResolution.notFound();
  }

  /// قراءة مساحة العمل المرتبطة بالبريد الإلكتروني من الفهرس السحابي — '' إن لم تُسجَّل بعد.
  static Future<String> lookupByEmail({
    required String backendUrl,
    required String email,
  }) async {
    final res = await resolveWorkspaceInCloud(
      backendUrl: backendUrl,
      email: email,
    );
    return res.found ? res.workspaceId : '';
  }

  /// تسجيل ربط مساحة العمل بالبريد الإلكتروني في الفهرس السحابي وبيانات المساحة (meta)
  /// وقائمة منشآت المستخدم (`user_workspaces`).
  static Future<void> bindEmailWorkspace({
    required String backendUrl,
    required String email,
    required String workspaceId,
    Map<String, Object?>? extraMeta,
    bool force = false,
  }) async {
    final clean = email.trim().toLowerCase();
    if (clean.isEmpty || workspaceId.isEmpty || workspaceId == 'default') return;
    try {
      String targetWs = workspaceId;
      if (!force) {
        // منع إضافة مساحة ثانية لنفس البريد الإلكتروني تلقائياً إذا كانت له مساحة سابقة مسجلة.
        final existing =
            await lookupByEmail(backendUrl: backendUrl, email: clean);
        if (existing.isNotEmpty && existing != 'default') {
          targetWs = existing;
        }
      }

      // (تدقيق 2026-11-04) PATCH بدل PUT: دمج الحقول دون مسح ما كتبته تدفقات
      // أخرى (الاشتراك/الحالة/الملكية) في نفس العقدة.
      await _authedPatch(
        _emailIndexPath(backendUrl, clean),
        body: jsonEncode({
          'workspaceId': targetWs,
          'email': clean,
          if (extraMeta != null) ...extraMeta,
          'updated_at': {'.sv': 'timestamp'},
        }),
      );

      final root = backendUrl.replaceAll(RegExp(r'/+$'), '');
      // meta.json بالـPATCH حصراً — PUT كان يمحو حقول الاشتراك والحالة كاملة.
      await _authedPatch(
        '$root/workspaces/${Uri.encodeComponent(targetWs)}/meta.json',
        body: jsonEncode({
          'id': targetWs,
          'owner_email': clean,
          if (extraMeta != null) ...extraMeta,
          'updated_at': {'.sv': 'timestamp'},
        }),
      );

      // تسجيل المنشأة أيضاً في سجل منشآت المستخدم لتمكينه من التبديل بين منشآته بسهولة
      try {
        await _authedPatch(
          '$root/workspaces/_registry/user_workspaces/${emailToKey(clean)}/${Uri.encodeComponent(targetWs)}.json',
          body: jsonEncode({
            'workspaceId': targetWs,
            'ownerEmail': clean,
            'role': 'owner',
            if (extraMeta != null) ...extraMeta,
            'updated_at': {'.sv': 'timestamp'},
          }),
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {}
    } catch (_) {}
  }

  /// قراءة مساحة الحساب من الفهرس — '' إن لم تُسجَّل بعد.
  static Future<String> lookup({
    required String backendUrl,
    required String uid,
  }) async {
    try {
      final res = await _authedGet(
        _indexPath(backendUrl, uid),
        timeout: const Duration(seconds: 12),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return '';
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.isEmpty || body == 'null') return '';
      final m = jsonDecode(body);
      if (m is! Map) return '';
      final ws = '${m['workspaceId'] ?? m['workspace_id'] ?? ''}'.trim();
      return ws == 'default' ? '' : ws;
    } catch (_) {
      return '';
    }
  }

  /// تسجيل ربط الحساب بمساحته (لا يُستبدل ربط قائم بمساحة أخرى إلا عند التوجيه الصريح force).
  static Future<void> bind({
    required String backendUrl,
    required String uid,
    required String workspaceId,
    String email = '',
    String phone = '',
    Map<String, Object?>? extraMeta,
    bool force = false,
  }) async {
    if (workspaceId.isEmpty || workspaceId == 'default') return;
    try {
      if (!force && uid.isNotEmpty) {
        final existing = await lookup(backendUrl: backendUrl, uid: uid);
        if (existing.isNotEmpty && existing != workspaceId) return;
      }
      if (uid.isNotEmpty) {
        try {
          // (تدقيق 2026-11-04) PATCH: الحفاظ على الحقول المرافقة (الهاتف/الوسوم).
          await _authedPatch(
            _indexPath(backendUrl, uid),
            body: jsonEncode({
              'workspaceId': workspaceId,
              'email': email.trim().toLowerCase(),
              if (phone.trim().isNotEmpty) 'phone': normalizePhone(phone),
              if (extraMeta != null) ...extraMeta,
              'updated_at': {'.sv': 'timestamp'},
            }),
          );
        } catch (_) {}
      }
      if (email.trim().isNotEmpty) {
        await bindEmailWorkspace(
          backendUrl: backendUrl,
          email: email,
          workspaceId: workspaceId,
          extraMeta: extraMeta,
          force: force,
        );
      }
      if (phone.trim().isNotEmpty) {
        final pwHash = '${extraMeta?['password_hash'] ?? ''}'.trim();
        await bindPhoneWorkspace(
          backendUrl: backendUrl,
          phone: phone,
          workspaceId: workspaceId,
          email: email,
          passwordHash: pwHash,
        );
      }
    } catch (_) {}
  }

  /// حساب عدد السجلات المحاسبية الفعّالة داخل حمولة نسخة/لقطة للمفاضلة بين النسخ.
  static int _countPayloadRecords(Map<String, Object?>? payload) {
    if (payload == null) return 0;
    final data = payload['data'] is Map ? payload['data'] as Map : payload;
    int total = 0;
    for (final k in const [
      'accounts',
      'transactions',
      'vouchers',
      'items',
      'operations',
    ]) {
      final list = data[k];
      if (list is List) total += list.length;
    }
    return total;
  }

  /// ربط الحساب مع فحص وتوجيه الحسابات (Workspace Resolver / Auth Gate):
  ///   • يفحص عقدة مساحات العمل في Firebase Realtime Database (`owner_email == currentUser.email` أو عضو في `roster`).
  ///   • السيناريو الأول (المستخدم لديه منشأة سابقة): يجلب `workspaceId` ويعينه كمعرف نشط ويفتح `nexora_${workspaceId}.db`.
  ///   • السيناريو الثاني (المستخدم جديد تماماً ولا يملك أي منشأة): عند تفعيل `forceIsolateNewUser` أو اختلاف المالك،
  ///     يمنع فتح أو ربط أي بيانات سابقة على الهاتف ويعزله لإنشاء منشأة جديدة.
  static Future<AccountLinkOutcome> linkAccountOnly(
    Repo repo, {
    required String backendUrl,
    required FirebaseAccount account,
    bool forceIsolateNewUser = false,
  }) async {
    if (account.uid.isEmpty && account.email.trim().isEmpty) {
      return AccountLinkOutcome.failed;
    }
    try {
      // جهاز عضو في مجموعة لا يُمَسّ ولا يُسمح له بتسجيل حساب Google أثناء ارتباطه بالمنشأة.
      if (await repo.workspaceMode() == 'member') {
        return AccountLinkOutcome.memberUntouched;
      }

      // تفعيل توكن الحساب أو التوكن الصامت فوراً لضمان نجاح كافة استعلامات البحث والاسترداد في السحابة
      FirebaseAuthRest.primeAccountInMemory(account);
      if (FirebaseAuthRest.cachedIdToken == null ||
          FirebaseAuthRest.cachedIdToken!.isEmpty) {
        try {
          await FirebaseAuthRest.initSilentAuth(repo)
              .timeout(const Duration(seconds: 6));
        } catch (_) {}
      }

      // فحص الهوية السابقة للمنشأة المحلية قبل أي تعديل لمنع تداخل بيانات الحسابات
      final stBefore = await repo.settings();
      String wsOwnerEmail = '';
      String wsOwnerUid = '';
      try {
        final db0 = await repo.database;
        final wsRows = await db0.query(
          'workspaces',
          where: 'id = ?',
          whereArgs: [repo.requireWorkspaceId],
          limit: 1,
        );
        if (wsRows.isNotEmpty) {
          wsOwnerEmail = '${wsRows.first['owner_email'] ?? ''}'.trim();
          wsOwnerUid = '${wsRows.first['owner_google_id'] ?? ''}'.trim();
        }
      } catch (_) {}

      final prevEmail = (stBefore['account.email'] ??
              stBefore['email'] ??
              stBefore[FirebaseAuthRest.lastOwnerEmailKey] ??
              wsOwnerEmail)
          .trim()
          .toLowerCase();
      final prevUid = (stBefore['account.uid'] ??
              stBefore[FirebaseAuthRest.lastOwnerUidKey] ??
              wsOwnerUid)
          .trim();
      final incomingEmail = account.email.trim().toLowerCase();
      final incomingUid = account.uid.trim();
      final isDifferentAccount = (prevEmail.isNotEmpty &&
              incomingEmail.isNotEmpty &&
              prevEmail != incomingEmail) ||
          (prevUid.isNotEmpty &&
              incomingUid.isNotEmpty &&
              prevUid != incomingUid &&
              (prevEmail.isEmpty || prevEmail != incomingEmail));

      // ══ (معالج فحص وتوجيه الحسابات — Workspace Resolver / Auth Gate) ══
      if (backendUrl.isNotEmpty) {
        final localWs = repo.requireWorkspaceId;
        String remoteWs = '';
        CloudWorkspaceResolution? resolution;
        try {
          resolution = await resolveWorkspaceInCloud(
            backendUrl: backendUrl,
            email: account.email,
            uid: account.uid,
          ).timeout(
            const Duration(seconds: 8),
            onTimeout: () => const CloudWorkspaceResolution.timeout(),
          );
          if (resolution.found) {
            remoteWs = resolution.workspaceId;
          }
          // إذا لم يُعثر على المنشأة في السحابة (أو كان الاتصال ضعيفاً)، نفحص قواعد البيانات المحفوظة محلياً على الجهاز لنفس البريد
          if (remoteWs.isEmpty &&
              !repo.hasCustomDatabaseProvider &&
              incomingEmail.isNotEmpty) {
            final localMatches = await findLocalWorkspacesOnDevice(
              filterEmail: incomingEmail,
            );
            if (localMatches.isNotEmpty) {
              remoteWs = localMatches.first.workspaceId;
              resolution = CloudWorkspaceResolution(
                workspaceId: remoteWs,
                role: localMatches.first.role,
                meta: localMatches.first.toJson(),
              );
            }
          }
          // لا يُفحص رقم الهاتف المحلي إلا إذا لم يكن الجهاز مملوكاً لبريد سابق مختلف ولم يكن مستخدماً جديداً معزولاً
          if (remoteWs.isEmpty &&
              !forceIsolateNewUser &&
              !isDifferentAccount &&
              prevEmail.isEmpty &&
              prevUid.isEmpty) {
            final savedPhone = (stBefore['phone'] ??
                    stBefore['whatsapp'] ??
                    stBefore['user.phone'] ??
                    '')
                .trim();
            if (savedPhone.isNotEmpty) {
              remoteWs = await lookupByPhone(
                      backendUrl: backendUrl, phone: savedPhone)
                  .timeout(const Duration(seconds: 6), onTimeout: () => '');
            }
          }
        } catch (_) {}

        final localAccounts =
            await repo.accounts(includeArchived: true, includeDeleted: true);

        if (remoteWs.isNotEmpty &&
            remoteWs != 'default' &&
            (remoteWs != localWs ||
                isDifferentAccount ||
                forceIsolateNewUser ||
                localAccounts.isEmpty)) {
          final outcome = await _switchWorkspace(
            repo,
            backendUrl: backendUrl,
            account: account,
            fromWorkspaceId: localWs,
            toWorkspaceId: remoteWs,
            resolutionMeta: resolution?.meta,
          ).timeout(const Duration(seconds: 35),
              onTimeout: () => AccountLinkOutcome.failed);
          if (outcome == AccountLinkOutcome.switched) {
            await FirebaseAuthRest.saveSession(repo, account);
            if (account.email.trim().isNotEmpty) {
              await repo.setSetting('account.email', account.email.trim());
              await repo.setSetting('email', account.email.trim());
            }
            final resolvedRole = resolution?.role ?? 'owner';
            if (resolvedRole == 'member') {
              await repo.ensureSelfPermissionRow(
                  roleCode: resolution?.memberRoleCode ?? 'cashier');
            } else {
              await repo.checkAndAutoPromoteManager();
              await repo.ensureSelfPermissionRow(roleCode: 'admin');
              await repo.restoreManagerOwnership();
            }
            await repo.setSetting('has_completed_onboarding', '1');
            await repo.setSetting('onboardingCompleted', '1');
            final stAfter = await repo.settings();
            await saveWorkspaceToLocalRegistry(
              WorkspaceInfo(
                workspaceId: remoteWs,
                storeName: (stAfter['businessName'] ?? 'منشأتي').trim(),
                businessActivity: (stAfter['businessActivity'] ?? '').trim(),
                defaultCurrency: (stAfter['defaultCurrency'] ?? 'YER').trim(),
                phone: (stAfter['phone'] ?? stAfter['whatsapp'] ?? '').trim(),
                ownerEmail: account.email.trim().toLowerCase(),
                role: resolvedRole,
                isCurrent: true,
              ),
            );
            await FirebaseAuthRest.saveWorkspaceSessionPrefs(
              workspaceId: remoteWs,
              userRole: resolvedRole == 'member'
                  ? (resolution?.memberRoleCode ?? 'member')
                  : 'owner',
              businessName: (stAfter['businessName'] ?? '').trim(),
              ownerEmail: account.email.trim().toLowerCase(),
              ownerUid: account.uid,
              displayName: account.displayName,
            );
            await _afterLink(repo, backendUrl, account, remoteWs)
                .timeout(const Duration(seconds: 8), onTimeout: () {})
                .catchError((_) {});
          }
          // ⚠️ حاسم: طالما وُجدت مساحة سابقة (remoteWs) لهذا البريد/الحساب،
          // يُمنع منعاً باتاً المتابعة لربط المساحة المحلية الفارغة (localWs)
          // أو الكتابة فوق الفهرس السحابي بمساحة ثانية!
          return outcome;
        }
      }

      // السيناريو الثاني (المستخدم جديد تماماً ولا يملك أي منشأة على السحابة):
      // ══ (إصلاح المنشآت الوهمية — Ghost Workspaces) ══
      // هذا المسار مقصور حصرياً على الطلب الصريح forceIsolateNewUser == true.
      // لا يُولَّد معرف مساحة جديد ولا تُنشأ قاعدة بيانات افتراضية
      // (nexora_WS-XXXX.db) من خلف المستخدم أثناء تسجيل الدخول العادي،
      // حتى لو اختلف البريد الوارد عن بريد الجهاز السابق: في تلك الحالة
      // يبقى التوجيه للمنشأة المعتمدة أعلاه (سحابياً أو محلياً) هو الحكم.
      if (forceIsolateNewUser) {
        try {
          final oldData =
              await repo.exportAll(withImages: false, localOnly: true);
          await FactoryReset.silentBackup(oldData,
              fileName: FactoryReset.kBackupBeforeSwitch);
        } catch (_) {}
        final newWsId = generateWorkspaceId();
        await repo.isolateForWorkspaceSwitch(
          targetWorkspaceId: newWsId,
          resetOnboarding: false,
        );
        await repo.setSetting('onboardingCompleted', '1');
        await repo.setSetting('has_completed_onboarding', '1');
        await FirebaseAuthRest.resetAnonymousSession(repo);
        await FirebaseAuthRest.ensureScopedAnonymous(repo, newWsId);
        await FirebaseAuthRest.initSilentAuth(repo);
        await FirebaseAuthRest.saveSession(repo, account);
        if (account.email.trim().isNotEmpty) {
          await repo.setSetting('account.email', account.email.trim());
          await repo.setSetting('email', account.email.trim());
        }
        if (account.displayName.trim().isNotEmpty) {
          await repo.setSetting('account.name', account.displayName.trim());
        }
        await repo.setSetting('account.type', 'enterprise');
        await repo.checkAndAutoPromoteManager();
        await repo.ensureSelfPermissionRow(roleCode: 'admin');
        await repo.restoreManagerOwnership(syncToCloud: false);
        if (backendUrl.isNotEmpty) {
          await _afterLink(repo, backendUrl, account, newWsId)
              .timeout(const Duration(seconds: 6), onTimeout: () {})
              .catchError((_) {});
        }
        return AccountLinkOutcome.isolatedNewWorkspace;
      }

      // (Offline-First) الجلسة تُحفظ أولاً — نجاح الربط لا يعتمد على الشبكة.
      await AppDatabase.instance.openForWorkspace(repo.requireWorkspaceId);
      await FirebaseAuthRest.saveSession(repo, account);
      if (account.email.trim().isNotEmpty) {
        await repo.setSetting('account.email', account.email.trim());
      }
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      await repo.restoreManagerOwnership();

      if (backendUrl.isNotEmpty) {
        await _afterLink(repo, backendUrl, account, repo.requireWorkspaceId)
            .timeout(const Duration(seconds: 6), onTimeout: () {})
            .catchError((_) {});
      }
      return AccountLinkOutcome.migrated;
    } catch (_) {
      return AccountLinkOutcome.failed;
    }
  }

  /// (دفعة 65) تنفيذ التبديل الآمن إلى مساحة أخرى واسترجاع كافة بياناتها: **الدمج ممنوع**.
  static Future<AccountLinkOutcome> _switchWorkspace(
    Repo repo, {
    required String backendUrl,
    required FirebaseAccount account,
    required String fromWorkspaceId,
    required String toWorkspaceId,
    Map<String, dynamic>? resolutionMeta,
  }) async {
    final root = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final wsUrl = '$root/workspaces/${Uri.encodeComponent(toWorkspaceId)}';

    // 1) سحب نسخة المساحة السابقة (backup.json) وكذلك فحص اللقطات (joinSnapshot.json / snapshot.json)
    //    واختيار النسخة الأغنى بالبيانات المحاسبية لضمان عدم الاكتفاء بنسخة تأسيس أولية فارغة.
    Map<String, Object?>? backupPulled;
    try {
      backupPulled = await AutoBackupService.pullWorkspaceBackup(repo,
          backendUrl: backendUrl, workspaceId: toWorkspaceId);
    } catch (_) {
      backupPulled = null;
    }

    Map<String, Object?>? snapPulled;
    for (final snapName in const ['joinSnapshot.json', 'snapshot.json']) {
      try {
        final snapRes = await _authedGet(
          '$wsUrl/$snapName',
          timeout: const Duration(seconds: 15),
        );
        if (snapRes.statusCode == 200 &&
            snapRes.body.trim().isNotEmpty &&
            snapRes.body.trim() != 'null') {
          final snapDecoded = jsonDecode(utf8.decode(snapRes.bodyBytes));
          if (snapDecoded is Map) {
            final dataMap = snapDecoded['data'] is Map
                ? snapDecoded['data']
                : ((snapDecoded['accounts'] != null ||
                        snapDecoded['settings'] != null)
                    ? snapDecoded
                    : null);
            if (dataMap is Map && dataMap.isNotEmpty) {
              final candidate = <String, Object?>{
                'format': 'nexora-backup',
                'data': Map<String, Object?>.from(dataMap),
              };
              if (_countPayloadRecords(candidate) >
                  _countPayloadRecords(snapPulled)) {
                snapPulled = candidate;
              }
            }
          }
        }
      } catch (_) {}
    }

    Map<String, Object?>? pulled = backupPulled;
    if (snapPulled != null) {
      if (pulled == null ||
          _countPayloadRecords(snapPulled) > _countPayloadRecords(pulled)) {
        // دمج إعدادات backupPulled داخل snapPulled إن كانت اللقطة لا تحتوي على بعض الإعدادات
        if (pulled != null &&
            pulled['data'] is Map &&
            snapPulled['data'] is Map) {
          final bData = pulled['data'] as Map;
          final sData = Map<String, Object?>.from(snapPulled['data'] as Map);
          if (sData['settings'] == null && bData['settings'] != null) {
            sData['settings'] = bData['settings'];
          }
          pulled = {
            'format': 'nexora-backup',
            'data': sData,
          };
        } else {
          pulled = snapPulled;
        }
      }
    }

    // قراءة meta.json و subscription.json للمساحة السابقة (لاسترجاع اسم المنشأة والعنوان والهاتف والعملة).
    Map<String, dynamic>? remoteMeta;
    try {
      final metaRes = await _authedGet(
        '$wsUrl/meta.json',
        timeout: const Duration(seconds: 10),
      );
      if (metaRes.statusCode == 200 &&
          metaRes.body.trim().isNotEmpty &&
          metaRes.body.trim() != 'null') {
        final d = jsonDecode(utf8.decode(metaRes.bodyBytes));
        if (d is Map) remoteMeta = Map<String, dynamic>.from(d);
      }
    } catch (_) {}

    if (remoteMeta == null) {
      try {
        final subRes = await _authedGet(
          '$wsUrl/subscription.json',
          timeout: const Duration(seconds: 8),
        );
        if (subRes.statusCode == 200 &&
            subRes.body.trim().isNotEmpty &&
            subRes.body.trim() != 'null') {
          final d = jsonDecode(utf8.decode(subRes.bodyBytes));
          if (d is Map) remoteMeta = Map<String, dynamic>.from(d);
        }
      } catch (_) {}
    }
    if (remoteMeta == null && resolutionMeta != null) {
      final hasStoreMeta = (resolutionMeta['storeName'] ??
                  resolutionMeta['store_name'] ??
                  resolutionMeta['businessName'] ??
                  '')
              .toString()
              .trim()
              .isNotEmpty;
      if (hasStoreMeta) {
        remoteMeta = Map<String, dynamic>.from(resolutionMeta);
      }
    }

    bool hasRemoteOperations = false;
    if (pulled == null && remoteMeta == null) {
      try {
        final opsRes = await _authedGet(
          '$wsUrl/operations.json?orderBy=%22%24key%22&limitToLast=1',
          timeout: const Duration(seconds: 8),
        );
        if (opsRes.statusCode == 200) {
          final opsBody = utf8.decode(opsRes.bodyBytes).trim();
          if (opsBody.isNotEmpty && opsBody != 'null' && opsBody != '{}') {
            hasRemoteOperations = true;
          }
        }
      } catch (_) {}
    }

    // إذا لم توجد backup.json أو snapshot.json بعد، ولكن توجد meta.json أو subscription.json
    // أو كانت المنشأة مسجلة في السحابة وعملياتها في /operations، نبني حمولة استعادة أولية
    // ليتم التحول فوراً إلى المساحة الأصلية ويسحب CloudFirebaseTransport.pull كافة العمليات من /operations.
    if (pulled == null && (remoteMeta != null || hasRemoteOperations)) {
      final settingsRows = <Map<String, Object?>>[];
      void addSetting(String k, Object? v) {
        final s = '${v ?? ''}'.trim();
        if (s.isNotEmpty) settingsRows.add({'key': k, 'value': s});
      }

      if (remoteMeta != null) {
        addSetting(
            'businessName',
            remoteMeta['storeName'] ??
                remoteMeta['store_name'] ??
                remoteMeta['businessName']);
        addSetting('businessActivity', remoteMeta['businessActivity']);
        addSetting('address', remoteMeta['address']);
        addSetting('phone', remoteMeta['phone'] ?? remoteMeta['whatsapp']);
        addSetting('whatsapp', remoteMeta['phone'] ?? remoteMeta['whatsapp']);
        addSetting('defaultCurrency', remoteMeta['defaultCurrency'] ?? 'YER');
        addSetting(
            'account.email', remoteMeta['owner_email'] ?? account.email.trim());
        addSetting(
            'account.name',
            remoteMeta['owner_name'] ??
                remoteMeta['clientName'] ??
                remoteMeta['client_name'] ??
                account.displayName);
      } else {
        addSetting('account.email', account.email.trim());
        addSetting('account.name', account.displayName);
      }
      if (settingsRows.isNotEmpty) {
        pulled = {
          'format': 'nexora-backup',
          'data': {
            'settings': settingsRows,
          },
        };
      }
    }

    // فحص ما إذا كانت قاعدة البيانات المحلية للمنشأة المستهدفة موجودة مسبقاً على الجهاز وتحتوي على بياناتها
    bool hasExistingLocalTargetDb = false;
    int existingLocalRecordsCount = 0;
    if (!repo.hasCustomDatabaseProvider &&
        toWorkspaceId.isNotEmpty &&
        toWorkspaceId != 'default') {
      try {
        final diskList =
            await AppDatabase.instance.scanWorkspaceDatabasesOnDisk();
        for (final item in diskList) {
          if ((item['workspaceId'] ?? '').trim() == toWorkspaceId) {
            final stName = (item['storeName'] ?? '').trim();
            final accCount = int.tryParse(item['accountsCount'] ?? '0') ?? 0;
            if (accCount > 0 ||
                (stName.isNotEmpty &&
                    stName != 'متجري' &&
                    stName != 'منشأتي')) {
              hasExistingLocalTargetDb = true;
              existingLocalRecordsCount = accCount;
            }
            break;
          }
        }
      } catch (_) {}
    }

    if (pulled == null && !hasExistingLocalTargetDb) {
      return AccountLinkOutcome.switchUnavailable;
    }

    // 2) نسخة احتياطية صامتة — نُبقي البيانات في الذاكرة أيضاً:
    Map<String, Object?>? backupData;
    try {
      final data = await repo.exportAll(withImages: false, localOnly: true);
      backupData = data;
      await FactoryReset.silentBackup(data,
          fileName: FactoryReset.kBackupBeforeSwitch);
    } catch (_) {}

    var swapped = false;
    try {
      // 3) فتح قاعدة البيانات الخاصة بالمساحة المستهدفة.
      if (!repo.hasCustomDatabaseProvider) {
        await AppDatabase.instance.openForWorkspace(toWorkspaceId);
      }
      final db = await repo.database;
      final pulledRecordsCount = _countPayloadRecords(pulled);
      final shouldImportPulled = pulled != null &&
          (repo.hasCustomDatabaseProvider ||
              !hasExistingLocalTargetDb ||
              pulledRecordsCount >= existingLocalRecordsCount);

      if (shouldImportPulled) {
        await FactoryReset.wipeAccountingTables(db);
      }

      // 4) ترحيل المساحة ثم استيراد بياناتها (مع السماح باختلاف بصمة الجهاز بعد إعادة التثبيت).
      if (fromWorkspaceId != toWorkspaceId) {
        await WorkspaceRecovery.swapWorkspaceId(db,
            from: fromWorkspaceId, to: toWorkspaceId);
        swapped = true;
        await repo.setSetting('sync.workspaceId', toWorkspaceId);
        repo.debugSetWorkspaceId(toWorkspaceId);
      }
      if (shouldImportPulled) {
        await repo.importAll(pulled, allowCrossFingerprint: true);
      }

      // استرجاع إعدادات المنشأة من meta.json / subscription.json إن وُجدت ولم تكن في النسخة
      if (remoteMeta != null) {
        final curSt = await repo.settings();
        Future<void> restoreIfMissing(
            String settingKey, List<String> metaKeys) async {
          final currentVal = (curSt[settingKey] ?? '').trim();
          if (currentVal.isNotEmpty &&
              currentVal != 'متجري' &&
              currentVal != 'منشأتي') {
            return;
          }
          for (final mk in metaKeys) {
            final mv = '${remoteMeta![mk] ?? ''}'.trim();
            if (mv.isNotEmpty) {
              await repo.setSetting(settingKey, mv);
              break;
            }
          }
        }

        await restoreIfMissing(
            'businessName', ['storeName', 'store_name', 'businessName']);
        await restoreIfMissing('businessActivity', ['businessActivity']);
        await restoreIfMissing('address', ['address']);
        await restoreIfMissing('phone', ['phone', 'whatsapp']);
        await restoreIfMissing('whatsapp', ['whatsapp', 'phone']);
        await restoreIfMissing('defaultCurrency', ['defaultCurrency']);
        await restoreIfMissing(
            'account.name', ['owner_name', 'clientName', 'client_name']);
      }

      // تصفير مؤشر السحب قبل الجلب الشامل لضمان استرجاع كافة العمليات من /operations
      try {
        await db.delete(
          'sync_meta',
          where: 'key IN (?, ?, ?)',
          whereArgs: [
            'last_synced_cursor:$toWorkspaceId',
            'last_synced_cursor',
            'lastCloudTs:$toWorkspaceId',
          ],
        );
      } catch (_) {}

      // سحب كافة عمليات المزامنة من عقدة /operations للمساحة المسترجعة وتطبيقها محلياً
      try {
        await CloudFirebaseTransport(
          repo: repo,
          dbProvider: () => repo.database,
          backendUrl: backendUrl,
          workspaceId: toWorkspaceId,
          idTokenProvider: () => FirebaseAuthRest.cloudIdToken(),
        ).pull(forceFullSync: true, resetCursor: true).timeout(const Duration(seconds: 25));
      } catch (_) {}

      // مزامنة قائمة الأجهزة والأعضاء للمنشأة المسترجعة
      try {
        await CloudJoin.syncRoster(
          repo,
          db,
          backendUrl: backendUrl,
          workspaceId: toWorkspaceId,
        ).timeout(const Duration(seconds: 8));
      } catch (_) {}

      // 5) هوية سحابية مستقلة مقترنة بالمساحة الجديدة.
      await FirebaseAuthRest.resetAnonymousSession(repo);
      await FirebaseAuthRest.ensureScopedAnonymous(repo, toWorkspaceId);
      await FirebaseAuthRest.initSilentAuth(repo);
      await FirebaseAuthRest.saveSession(repo, account);
      if (account.email.trim().isNotEmpty) {
        await repo.setSetting('account.email', account.email.trim());
        await repo.setSetting('email', account.email.trim());
      }
      if (account.displayName.trim().isNotEmpty) {
        final curName = ((await repo.settings())['account.name'] ?? '').trim();
        if (curName.isEmpty) {
          await repo.setSetting('account.name', account.displayName.trim());
        }
      }
      await repo.setSetting('account.type', 'enterprise');
      await repo.setSetting('onboardingCompleted', '1');
      await repo.setSetting('has_completed_onboarding', '1');
      await repo.setSetting('cloudWorkspaceProvisioned', '1');
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      await repo.restoreManagerOwnership();
      // تنظيف أي مساحات محلية يتيمة حتى تبقى مساحة واحدة فقط في الجهاز
      try {
        await repo.purgeNonEmailWorkspaces();
      } catch (_) {}
      try {
        await db.insert(
          'sync_meta',
          {'key': 'workspaceMode', 'value': 'host'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}
      return AccountLinkOutcome.switched;
    } catch (e) {
      debugPrint('AccountWorkspace: فشل التبديل بعد التفريغ: $e');
      return await _undoFailedSwitch(
        repo,
        backupData: backupData,
        fromWorkspaceId: fromWorkspaceId,
        toWorkspaceId: toWorkspaceId,
        swapped: swapped,
      );
    }
  }

  /// (دفعة 65) تراجع عن تبديل فاشل **بعد** التفريغ: يعكس ترحيل المساحة
  /// (إن حصل) ثم يستعيد بيانات المساحة الأصلية من النسخة المحتفظ بها.
  static Future<AccountLinkOutcome> _undoFailedSwitch(
    Repo repo, {
    required Map<String, Object?>? backupData,
    required String fromWorkspaceId,
    required String toWorkspaceId,
    required bool swapped,
  }) async {
    if (swapped) {
      try {
        final db = await repo.database;
        await WorkspaceRecovery.swapWorkspaceId(db,
            from: toWorkspaceId, to: fromWorkspaceId);
        await repo.setSetting('sync.workspaceId', fromWorkspaceId);
        repo.debugSetWorkspaceId(fromWorkspaceId);
      } catch (e) {
        debugPrint('AccountWorkspace: تعذّر عكس ترحيل المساحة: $e');
      }
    }
    if (backupData == null) return AccountLinkOutcome.switchDataLost;
    // (تدقيق 2026-11-04) إعادة فتح ملف قاعدة بيانات المنشأة الأصلية قبل
    // الاستعادة: مسار التبديل فتح ملف المنشأة الجديدة وبقي فعّالاً، فكانت
    // استعادة النسخة تكتب بيانات المنشأة القديمة داخل ملف المنشأة الجديدة.
    try {
      if (!repo.hasCustomDatabaseProvider) {
        await AppDatabase.instance.openForWorkspace(fromWorkspaceId);
      }
      await repo.setSetting('sync.workspaceId', fromWorkspaceId);
      repo.debugSetWorkspaceId(fromWorkspaceId);
    } catch (e) {
      debugPrint('AccountWorkspace: تعذّر إعادة فتح قاعدة المنشأة الأصلية: $e');
    }
    try {
      await repo.importAll(backupData, allowCrossFingerprint: true);
      return AccountLinkOutcome.switchRestored;
    } catch (e) {
      debugPrint('AccountWorkspace: تعذّر استرجاع النسخة: $e');
      return AccountLinkOutcome.switchDataLost;
    }
  }

  /// هل استوفى التسجيل كافة الحقول الإلزامية للمنشأة أو الحساب الفردي؟
  /// (الاسم التجاري، رقم الهاتف، البريد الإلكتروني، النشاط، العملة).
  /// في حال عدم الاكتمال، تُحفظ مسودة محلية فقط دون إرسال أي طلب لفايربيس.
  static Future<bool> isMandatoryRegistrationComplete(
    Repo repo, {
    String? emailOverride,
  }) async {
    if (debugForceLegacyWorkspaceId) return true;
    try {
      final mode = await repo.workspaceMode();
      if (mode == 'member') return true;
    } catch (_) {}
    try {
      final st = await repo.settings();
      if ((st['onboardingCompleted'] ?? '') != '0') {
        if (Platform.environment.containsKey('FLUTTER_TEST')) {
          return true;
        }
        final db = await repo.database;
        final dbPath = db.path;
        if (dbPath.isEmpty ||
            dbPath == ':memory:' ||
            dbPath.contains('in_memory')) {
          return true;
        }
      }
      final storeName = (st['businessName'] ?? '').trim();
      final phone = (st['phone'] ?? st['whatsapp'] ?? '')
          .replaceAll(RegExp(r'[^0-9]'), '');
      final email =
          (emailOverride ?? st['account.email'] ?? st['email'] ?? '').trim();
      final activity = (st['businessActivity'] ?? '').trim();
      final currency =
          (st['defaultCurrency'] ?? st['currency'] ?? '').trim();

      return storeName.isNotEmpty &&
          storeName != 'متجري' &&
          storeName != 'منشأتي' &&
          phone.length >= 6 &&
          email.isNotEmpty &&
          email.contains('@') &&
          activity.isNotEmpty &&
          currency.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// ربط هوية الجهاز داخل المنشأة بالبريد الإلكتروني للعضو المسجل (Email) مع رقم الجوال:
  /// عند تسجيل الدخول أو إعادة فتح التطبيق، يفحص قائمة أجهزة المنشأة (`roster` و `devices`):
  /// إذا كان هناك جهاز مسجل بنفس البريد الإلكتروني للمستخدم، يُعاد استخدام نفس الـ `deviceId`
  /// المسجل مسبقاً ولا يُنشأ جهاز جديد في الروستر، بل يتم فقط تحديث حقل `last_seen`.
  static Future<String> syncMemberDeviceInWorkspace(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String email,
    required String phone,
    required String displayName,
    bool isOwner = true,
  }) async {
    var devId = await ensureDeviceId(repo);
    final fpHash = await ensureHardwareFingerprintHash(repo);
    final cleanEmail = email.trim().toLowerCase();
    final cleanPhone = normalizePhone(phone);
    final root = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final encWs = Uri.encodeComponent(workspaceId);

    String? matchedDeviceId;
    Map<String, dynamic>? matchedRosterEntry;
    final duplicateIds = <String>{};

    Future<void> scanCloudNode(String nodeName) async {
      try {
        final res = await _authedGet(
          '$root/workspaces/$encWs/$nodeName.json',
          timeout: const Duration(seconds: 10),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) return;
        final body = utf8.decode(res.bodyBytes).trim();
        if (body.isEmpty || body == 'null') return;
        final map = jsonDecode(body);
        if (map is! Map) return;
        for (final entry in map.entries) {
          final v = entry.value;
          if (v is! Map) continue;
          final candId =
              '${v['device_id'] ?? v['deviceId'] ?? v['id'] ?? entry.key}'
                  .trim();
          if (candId.isEmpty) continue;
          final candEmail =
              '${v['email'] ?? v['user_email'] ?? v['owner_email'] ?? ''}'
                  .trim()
                  .toLowerCase();
          final candPhone =
              normalizePhone('${v['phone'] ?? v['phone_number'] ?? ''}');
          final candFp =
              '${v['fingerprint'] ?? v['hw_fingerprint'] ?? v['device_fingerprint'] ?? ''}'
                  .trim()
                  .toLowerCase();

          final sameEmail = cleanEmail.isNotEmpty &&
              candEmail.isNotEmpty &&
              candEmail == cleanEmail;
          final sameEmailAndPhone = sameEmail &&
              (cleanPhone.isEmpty ||
                  candPhone.isEmpty ||
                  candPhone == cleanPhone);
          final sameFp = fpHash.isNotEmpty &&
              candFp.isNotEmpty &&
              candFp == fpHash.toLowerCase();
          final sameId = candId.toUpperCase() == devId.toUpperCase();

          if (sameEmailAndPhone || sameEmail || sameFp || sameId) {
            if (matchedDeviceId == null) {
              matchedDeviceId = candId;
              if (nodeName == 'roster' || matchedRosterEntry == null) {
                matchedRosterEntry = Map<String, dynamic>.from(v);
              }
            } else if (candId.toUpperCase() != matchedDeviceId!.toUpperCase()) {
              duplicateIds.add(candId);
            }
          }
        }
      } catch (_) {}
    }

    await scanCloudNode('roster');
    await scanCloudNode('devices');

    if (matchedDeviceId != null && matchedDeviceId!.isNotEmpty) {
      if (matchedDeviceId != devId) {
        duplicateIds.add(devId);
        devId = await adoptCanonicalDeviceId(
          repo,
          matchedDeviceId!,
          fingerprint: fpHash,
        );
      }

      // تنظيف أي سجلات أجهزة مكررة سابقة لنفس البريد/الجوال
      for (final dupId in duplicateIds) {
        if (dupId.toUpperCase() != devId.toUpperCase()) {
          try {
            final encDup = Uri.encodeComponent(dupId);
            await _authedDelete(
              '$root/workspaces/$encWs/roster/$encDup.json',
              timeout: const Duration(seconds: 8),
            );
            await _authedDelete(
              '$root/workspaces/$encWs/devices/$encDup.json',
              timeout: const Duration(seconds: 8),
            );
          } catch (_) {}
        }
      }

      // تحديث حقل last_seen فقط لنفس الـ deviceId المسجل مسبقاً دون إنشاء جهاز جديد
      final encDev = Uri.encodeComponent(devId);
      final nameToUse = displayName.trim().isNotEmpty
          ? displayName.trim()
          : '${matchedRosterEntry?['name'] ?? matchedRosterEntry?['device_name'] ?? devId}';
      try {
        await _authedPatch(
          '$root/workspaces/$encWs/roster/$encDev.json',
          body: jsonEncode({
            'id': devId,
            'device_id': devId,
            'deviceId': devId,
            'name': nameToUse,
            if (cleanEmail.isNotEmpty) 'email': cleanEmail,
            if (phone.trim().isNotEmpty) 'phone': phone.trim(),
            if (fpHash.isNotEmpty) 'fingerprint': fpHash,
            'last_seen': {'.sv': 'timestamp'},
            'last_seen_at': {'.sv': 'timestamp'},
          }),
          timeout: const Duration(seconds: 10),
        );
        await _authedPatch(
          '$root/workspaces/$encWs/devices/$encDev.json',
          body: jsonEncode({
            'deviceId': devId,
            'device_id': devId,
            'deviceName': nameToUse,
            'device_name': nameToUse,
            if (cleanEmail.isNotEmpty) 'email': cleanEmail,
            if (phone.trim().isNotEmpty) 'phone': phone.trim(),
            if (fpHash.isNotEmpty) 'fingerprint': fpHash,
            if (fpHash.isNotEmpty) 'hw_fingerprint': fpHash,
            'last_seen': {'.sv': 'timestamp'},
            'lastSeenAt': {'.sv': 'timestamp'},
            'last_seen_at': {'.sv': 'timestamp'},
          }),
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {}
      return devId;
    }

    // تسجيل الجهاز لأول مرة مع ربطه بالبريد الإلكتروني ورقم الجوال
    final encDev = Uri.encodeComponent(devId);
    final nameToUse =
        displayName.trim().isNotEmpty ? displayName.trim() : devId;
    try {
      await _authedPut(
        '$root/workspaces/$encWs/roster/$encDev.json',
        body: jsonEncode({
          'id': devId,
          'device_id': devId,
          'deviceId': devId,
          'name': nameToUse,
          if (cleanEmail.isNotEmpty) 'email': cleanEmail,
          if (phone.trim().isNotEmpty) 'phone': phone.trim(),
          if (fpHash.isNotEmpty) 'fingerprint': fpHash,
          'role': isOwner ? 'owner' : 'member',
          'is_owner': isOwner,
          'joined_at': {'.sv': 'timestamp'},
          'last_seen': {'.sv': 'timestamp'},
          'last_seen_at': {'.sv': 'timestamp'},
        }),
        timeout: const Duration(seconds: 10),
      );
      await _authedPut(
        '$root/workspaces/$encWs/devices/$encDev.json',
        body: jsonEncode({
          'deviceId': devId,
          'device_id': devId,
          'deviceName': nameToUse,
          'device_name': nameToUse,
          if (cleanEmail.isNotEmpty) 'email': cleanEmail,
          if (phone.trim().isNotEmpty) 'phone': phone.trim(),
          if (fpHash.isNotEmpty) 'fingerprint': fpHash,
          if (fpHash.isNotEmpty) 'hw_fingerprint': fpHash,
          'is_owner': isOwner,
          'linkedAt': {'.sv': 'timestamp'},
          'linked_at': {'.sv': 'timestamp'},
          'last_seen': {'.sv': 'timestamp'},
          'lastSeenAt': {'.sv': 'timestamp'},
          'last_seen_at': {'.sv': 'timestamp'},
        }),
        timeout: const Duration(seconds: 10),
      );
    } catch (_) {}
    return devId;
  }

  /// تثبيت الربط بعد أي مسار ناجح: جلسة + فهرس الحساب + فهرس البريد + فهرس الهاتف +
  /// فهرس البصمة + ربط الـ workspace بحساب Google في الجدول المحلي.
  /// يُحظر إنشاء أي عقدة `/workspaces/{workspaceId}` في السحابة إلا بعد استكمال
  /// كافة حقول التسجيل الإلزامية (الاسم التجاري، الهاتف، البريد، النشاط، العملة).
  static Future<void> _afterLink(Repo repo, String backendUrl,
      FirebaseAccount account, String workspaceId) async {
    final previousUid = FirebaseAuthRest.anonymousUid;
    await FirebaseAuthRest.saveSession(repo, account);
    final st = await repo.settings();
    final phone = (st['phone'] ?? st['whatsapp'] ?? '').trim();
    final storeName = (st['businessName'] ?? '').trim();
    final address = (st['address'] ?? '').trim();
    final activity = (st['businessActivity'] ?? '').trim();
    final currency = (st['defaultCurrency'] ?? '').trim();
    final rawCustomName = (st['profile.owner_name'] ??
            st['account.name'] ??
            st['sync.deviceName'] ??
            '')
        .trim();
    final hasCustomOwnerName = rawCustomName.isNotEmpty &&
        rawCustomName != 'جهاز المحاسب' &&
        rawCustomName != 'جهاز مدير الحسابات';
    final ownerName = hasCustomOwnerName
        ? rawCustomName
        : (account.displayName.trim().isNotEmpty
            ? account.displayName.trim()
            : rawCustomName);

    try {
      final db = await repo.database;
      await db.update(
        'workspaces',
        {
          'owner_google_id': account.uid,
          'owner_email': account.email.trim().toLowerCase(),
          'owner_name': ownerName,
          if (storeName.isNotEmpty) 'name': storeName,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [workspaceId],
      );
    } catch (_) {}

    // منع إنشاء أي عقدة مساحة عمل في السحابة إلا بعد استكمال كافة الحقول الإلزامية
    final mandatoryComplete = await isMandatoryRegistrationComplete(
      repo,
      emailOverride: account.email,
    );
    if (!mandatoryComplete) {
      await ensureDeviceId(repo);
      return;
    }

    final extraMeta = <String, Object?>{
      if (storeName.isNotEmpty) 'storeName': storeName,
      if (ownerName.isNotEmpty) 'owner_name': ownerName,
      if (phone.isNotEmpty) 'phone': phone,
      if (address.isNotEmpty) 'address': address,
      if (activity.isNotEmpty) 'businessActivity': activity,
      if (currency.isNotEmpty) 'defaultCurrency': currency,
    };

    await bind(
      backendUrl: backendUrl,
      uid: account.uid,
      workspaceId: workspaceId,
      email: account.email,
      phone: phone,
      extraMeta: extraMeta,
      force: true,
    );
    try {
      await syncMemberDeviceInWorkspace(
        repo,
        backendUrl: backendUrl,
        workspaceId: workspaceId,
        email: account.email,
        phone: phone,
        displayName: ownerName,
        isOwner: true,
      );
    } catch (_) {}
    try {
      await CloudJoin.migrateOwnerMembership(repo,
          backendUrl: backendUrl,
          workspaceId: workspaceId,
          previousUid: previousUid);
    } catch (_) {}
    try {
      await DeviceRegistry.upsertBinding(repo,
          backendUrl: backendUrl, force: true);
    } catch (_) {}
    await repo.setSetting('cloudWorkspaceProvisioned', '1');
    await ensureDeviceId(repo);
  }

  /// مزامنة بيانات المنشأة والملف الشخصي (الاسم، الهاتف، العنوان، النشاط، البريد)
  /// مع عقدة meta.json والفهارس السحابية (emails_index / phones_index) + نسخة احتياطية فورية.
  static Future<void> syncWorkspaceMetaToCloud(
    Repo repo, {
    required String backendUrl,
  }) async {
    if (backendUrl.isEmpty) return;
    try {
      if (await repo.workspaceMode() == 'member') return;
      final wsId = repo.requireWorkspaceId;
      if (wsId.isEmpty || wsId == 'default') return;

      // منع إنشاء أو تحديث عقدة السحابة إلا بعد استكمال كافة الحقول الإلزامية
      if (!(await isMandatoryRegistrationComplete(repo))) {
        return;
      }

      final st = await repo.settings();
      final email = (st['account.email'] ?? st['email'] ?? '').trim();
      final phone = (st['phone'] ?? st['whatsapp'] ?? '').trim();
      final storeName = (st['businessName'] ?? '').trim();
      final address = (st['address'] ?? '').trim();
      final activity = (st['businessActivity'] ?? '').trim();
      final currency = (st['defaultCurrency'] ?? '').trim();
      final ownerName =
          (st['account.name'] ?? st['sync.deviceName'] ?? '').trim();
      final uid = await FirebaseAuthRest.savedUid(repo);

      final extraMeta = <String, Object?>{
        if (storeName.isNotEmpty) 'storeName': storeName,
        if (ownerName.isNotEmpty) 'owner_name': ownerName,
        if (phone.isNotEmpty) 'phone': phone,
        if (address.isNotEmpty) 'address': address,
        if (activity.isNotEmpty) 'businessActivity': activity,
        if (currency.isNotEmpty) 'defaultCurrency': currency,
      };

      await bind(
        backendUrl: backendUrl,
        uid: uid,
        workspaceId: wsId,
        email: email,
        phone: phone,
        extraMeta: extraMeta,
        force: true,
      );
      await syncMemberDeviceInWorkspace(
        repo,
        backendUrl: backendUrl,
        workspaceId: wsId,
        email: email,
        phone: phone,
        displayName: ownerName,
        isOwner: true,
      );
      await repo.setSetting('cloudWorkspaceProvisioned', '1');
      await AutoBackupService.silentWorkspaceBackup(repo, force: true);
    } catch (_) {}
  }

  /// حفظ معلومات المنشأة في السجل المحلي (`SharedPreferences`) ليتمكن المستخدم من التبديل بينها دون تداخل.
  /// ملاحظة: منشآت الأعضاء المنضمين (`role == 'member'`) لا تُحفظ أبداً في سجل الدخول السريع.
  static Future<void> saveWorkspaceToLocalRegistry(WorkspaceInfo info) async {
    if (info.workspaceId.isEmpty ||
        info.workspaceId == 'default' ||
        info.role.trim().toLowerCase() == 'member') {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw =
          prefs.getString(FirebaseAuthRest.prefsWorkspacesListKey) ?? '[]';
      final list = <Map<String, dynamic>>[];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              if ('${map['workspaceId'] ?? ''}'.trim() != info.workspaceId &&
                  '${map['role'] ?? ''}'.trim().toLowerCase() != 'member') {
                list.add(map);
              }
            }
          }
        }
      } catch (_) {}
      list.insert(0, info.toJson().map((k, v) => MapEntry(k, v)));
      await prefs.setString(
        FirebaseAuthRest.prefsWorkspacesListKey,
        jsonEncode(list),
      );
    } catch (_) {}
  }

  /// إزالة منشأة من سجل الدخول السريع المحلي (`SharedPreferences`) مع خيار حذف ملف قاعدة بياناتها من القرص.
  static Future<void> removeWorkspaceFromLocalRegistry(
    String workspaceId, {
    bool deleteDbFile = false,
  }) async {
    final cleanWs = workspaceId.trim();
    if (cleanWs.isEmpty || cleanWs == 'default') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw =
          prefs.getString(FirebaseAuthRest.prefsWorkspacesListKey) ?? '[]';
      final list = <Map<String, dynamic>>[];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              if ('${map['workspaceId'] ?? ''}'.trim() != cleanWs) {
                list.add(map);
              }
            }
          }
        }
      } catch (_) {}
      await prefs.setString(
        FirebaseAuthRest.prefsWorkspacesListKey,
        jsonEncode(list),
      );
      final activeWs =
          (prefs.getString(FirebaseAuthRest.prefsWorkspaceIdKey) ?? '').trim();
      if (activeWs == cleanWs) {
        await prefs.remove(FirebaseAuthRest.prefsWorkspaceIdKey);
      }
    } catch (_) {}
    if (deleteDbFile) {
      try {
        await AppDatabase.instance.deleteWorkspaceDatabaseFile(cleanWs);
      } catch (_) {}
    }
  }

  /// ══ (إصلاح المنشآت الوهمية — Self-Healing Cleanup) ══
  /// يحذف من القرص ملفات قواعد البيانات «الشبح» المولدة تلقائياً باسم
  /// `nexora_WS-*.db` حين تكون مسودات فارغة: بلا اسم تجاري حقيقي، وبلا
  /// حسابات أو حركات مالية. هذه المسودات كانت تظهر للعميل كمنشآت وهمية
  /// وكأنها فقدان لبياناته عند تسجيل الدخول بحساب Google.
  ///
  /// حدود الأمان الصارمة:
  ///  • لا يُمس ملف القاعدة الافتراضية ولا أي ملف لا يحمل بادئة `WS-`.
  ///  • لا يُمس ملف المساحة النشطة حالياً (المعطاة أو المقروءة من
  ///    AppDatabase.activeWorkspaceId).
  ///  • ملف المسودة التالف الذي يتعذر فتحه أصلاً يُحذف هو الآخر.
  static Future<void> purgeGhostWorkspaceDatabasesOnDisk({
    String currentWorkspaceId = '',
  }) async {
    // بيئة الاختبار تستخدم مزود قواعد وهمي — لا نلمس قرصاً حقيقياً.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final active = currentWorkspaceId.trim().isNotEmpty
          ? currentWorkspaceId.trim()
          : AppDatabase.activeWorkspaceId.trim();
      final dir = Directory(await databaseDirectory());
      if (!dir.existsSync()) return;

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) {
            final base = p.basename(f.path);
            return base.startsWith('nexora_WS-') && base.endsWith('.db');
          })
          .toList();

      for (final file in files) {
        final base = p.basename(file.path);
        final rawWs = base
            .substring('nexora_'.length, base.length - '.db'.length)
            .trim();
        // لا نمس المساحة النشطة أبداً مهما كانت.
        if (rawWs.isEmpty || rawWs == active) continue;

        Database? ghost;
        try {
          ghost = await openDatabase(file.path, readOnly: true);
        } catch (_) {
          // ملف تالف أو ليس قاعدة SQLite صالحة — مسودة شبح تُمسح.
          await _safeDeleteDbFile(file.path);
          continue;
        }
        try {
          // (أ) الاسم التجاري الحقيقي.
          var storeName = '';
          try {
            final stRows = await ghost.query(
              'settings',
              where: "key = 'businessName'",
              limit: 1,
            );
            if (stRows.isNotEmpty) {
              storeName = '${stRows.first['value'] ?? ''}'.trim();
            }
          } catch (_) {}

          // (ب) الحسابات والعمليات المالية.
          var accountsCount = 0;
          var transactionsCount = 0;
          for (final table in const ['accounts', 'transactions']) {
            try {
              final c = await ghost.rawQuery(
                  "SELECT COUNT(*) AS c FROM $table WHERE COALESCE(deleted_at,'') = ''");
              final n = int.tryParse('${c.first['c'] ?? 0}') ?? 0;
              if (table == 'accounts') {
                accountsCount = n;
              } else {
                transactionsCount = n;
              }
            } catch (_) {}
          }

          final isGhost = isGhostWorkspaceSnapshot(
            storeName: storeName,
            accountsCount: accountsCount,
            transactionsCount: transactionsCount,
          );
          if (!isGhost) continue;

          // إغلاق المقبض قبل الحذف كي لا يبقى الملف مقفلاً على المنصة.
          try {
            await ghost.close();
          } catch (_) {}
          ghost = null;
          await _safeDeleteDbFile(file.path);
        } finally {
          try {
            await ghost?.close();
          } catch (_) {}
        }
      }
    } catch (_) {
      // التنظيف الذاتي لا يُفشل أي مسار استدعٍ أبداً.
    }
  }

  /// (Self-Healing) معيار «مسودة المنشأة الوهمية»: قاعدة ببادئة WS- بلا
  /// اسم تجاري حقيقي (فارغ أو الافتراضي «متجري»/«منشأتي») وبلا أي حسابات
  /// أو حركات مالية — هذه ليست منشأة عميل وإنما مسودة توليد تلقائي.
  @visibleForTesting
  static bool isGhostWorkspaceSnapshot({
    required String storeName,
    required int accountsCount,
    required int transactionsCount,
  }) {
    final sn = storeName.trim();
    final hasRealName =
        sn.isNotEmpty && sn != 'متجري' && sn != 'منشأتي';
    return !hasRealName && accountsCount == 0 && transactionsCount == 0;
  }

  /// حذف ملف قاعدة بيانات مع ملفاته المرافقة (-wal/-shm/-journal) بأمان.
  static Future<void> _safeDeleteDbFile(String dbPath) async {
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      try {
        final f = File('$dbPath$suffix');
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }

  /// فحص واسترجاع المنشآت المحفوظة محلياً على هذا الجهاز (من ملفات SQLite ومن SharedPreferences).
  static Future<List<WorkspaceInfo>> findLocalWorkspacesOnDevice({
    String? filterEmail,
    String currentWorkspaceId = '',
  }) async {
    final cleanFilter = (filterEmail ?? '').trim().toLowerCase();
    final mapByWs = <String, WorkspaceInfo>{};

    // (Self-Healing) تنظيف مسودات المنشآت الوهمية الفارغة من القرص أولاً:
    // أي ملف nexora_WS-*.db بلا اسم تجاري حقيقي وبلا حسابات أو حركات
    // يُحذف فوراً، فلا يظهر في أي قائمة ولا يعود مرشحاً للدخول أبداً.
    await purgeGhostWorkspaceDatabasesOnDisk(
      currentWorkspaceId: currentWorkspaceId,
    );

    // 1) فحص ملفات قواعد البيانات المعزولة على القرص (nexora_*.db)
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        final diskWorkspaces =
            await AppDatabase.instance.scanWorkspaceDatabasesOnDisk();
        for (final item in diskWorkspaces) {
          final wsId = (item['workspaceId'] ?? '').trim();
          if (wsId.isEmpty || wsId == 'default') continue;
          final storeName = (item['storeName'] ?? '').trim();
          final accountsCount =
              int.tryParse(item['accountsCount'] ?? '0') ?? 0;
          final isConfigured = (storeName.isNotEmpty &&
                  storeName != 'متجري' &&
                  storeName != 'منشأتي') ||
              accountsCount > 0;
          if (!isConfigured) continue;
          final ownerEmail =
              (item['ownerEmail'] ?? '').trim().toLowerCase();
          final defCurr = (item['defaultCurrency'] ?? 'YER').trim();
          final info = WorkspaceInfo(
            workspaceId: wsId,
            storeName: storeName.isEmpty ? 'منشأة ($wsId)' : storeName,
            businessActivity: (item['businessActivity'] ?? '').trim(),
            defaultCurrency: defCurr.isEmpty ? 'YER' : defCurr,
            phone: (item['phone'] ?? '').trim(),
            ownerEmail: ownerEmail,
            role: 'owner',
            isCurrent: wsId == currentWorkspaceId,
          );
          if (cleanFilter.isEmpty || ownerEmail == cleanFilter) {
            mapByWs[wsId] = info;
          }
        }
      } catch (_) {}
    }

    // 2) فحص السجل المحلي في SharedPreferences (مع استبعاد أي منشأة محفوظة بدور عضو)
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw =
          prefs.getString(FirebaseAuthRest.prefsWorkspacesListKey) ?? '[]';
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final info = WorkspaceInfo.fromJson(
              Map<String, dynamic>.from(item),
              isCurrent:
                  '${item['workspaceId'] ?? ''}'.trim() == currentWorkspaceId,
            );
            if (info.workspaceId.isEmpty ||
                info.workspaceId == 'default' ||
                info.role.trim().toLowerCase() == 'member') {
              continue;
            }
            // (Self-Healing) استبعاد مسودات المنشآت الوهمية من السجل أيضاً:
            // بلا اسم تجاري حقيقي، أو بادئة مسودة WS- مع الاسم الاحتياطي،
            // أو مدخل لا يقابله ملف قاعدة بيانات فعلي على القرص.
            final sn = info.storeName.trim();
            final isDraftEntry = sn.isEmpty ||
                sn == 'متجري' ||
                sn == 'منشأتي' ||
                (info.workspaceId.startsWith('WS-') &&
                    (sn.startsWith('منشأة (') || sn.startsWith('منشأة(')));
            if (isDraftEntry) continue;
            if (!Platform.environment.containsKey('FLUTTER_TEST')) {
              try {
                final dbFile = File(p.join(await databaseDirectory(),
                    'nexora_${info.workspaceId}.db'));
                if (!dbFile.existsSync()) continue;
              } catch (_) {}
            }
            if (cleanFilter.isEmpty ||
                info.ownerEmail.toLowerCase() == cleanFilter) {
              mapByWs.putIfAbsent(info.workspaceId, () => info);
            }
          }
        }
      }
    } catch (_) {}

    return mapByWs.values.toList();
  }

  /// جلب كافة المنشآت المرتبطة بالمستخدم أو المحفوظة على هذا الجهاز (محلياً وسحابياً).
  static Future<List<WorkspaceInfo>> listUserWorkspaces(
    Repo repo, {
    required String backendUrl,
    bool includeAllDeviceWorkspaces = true,
  }) async {
    final currentMode = await repo.workspaceMode();
    if (currentMode == 'member') {
      return const [];
    }
    final currentWs = repo.requireWorkspaceId;
    final st = await repo.settings();
    final email = (st['account.email'] ?? st['email'] ?? '')
        .trim()
        .toLowerCase();
    final mapByWs = <String, WorkspaceInfo>{};

    // 1) المنشأة النشطة حالياً (تُضاف فقط إن اكتمل إعداد اسمها التجاري الفعلي وليست مسودة عزل أولية)
    if (currentWs.isNotEmpty && currentWs != 'default') {
      final rawStoreName = (st['businessName'] ?? '').trim();
      final isConfigured = rawStoreName.isNotEmpty &&
          rawStoreName != 'متجري' &&
          rawStoreName != 'منشأتي';
      if (isConfigured) {
        final curInfo = WorkspaceInfo(
          workspaceId: currentWs,
          storeName: rawStoreName,
          businessActivity: (st['businessActivity'] ?? '').trim(),
          defaultCurrency: (st['defaultCurrency'] ?? 'YER').trim(),
          phone: (st['phone'] ?? st['whatsapp'] ?? '').trim(),
          ownerEmail: email,
          role: 'owner',
          isCurrent: true,
        );
        mapByWs[currentWs] = curInfo;
        await saveWorkspaceToLocalRegistry(curInfo);
      }
    }

    // 2) المنشآت المحفوظة محلياً على القرص وفي SharedPreferences
    final localList = await findLocalWorkspacesOnDevice(
      filterEmail: includeAllDeviceWorkspaces ? null : email,
      currentWorkspaceId: currentWs,
    );
    for (final info in localList) {
      mapByWs.putIfAbsent(info.workspaceId, () => info);
      await saveWorkspaceToLocalRegistry(info);
    }

    // 3) المنشآت المسجلة في السحابة لنفس البريد (user_workspaces + /workspaces)
    if (backendUrl.isNotEmpty && email.isNotEmpty) {
      final root = _trimSlashes(backendUrl);
      try {
        final uwRes = await _authedGet(
          '$root/workspaces/_registry/user_workspaces/${emailToKey(email)}.json',
          timeout: const Duration(seconds: 8),
        );
        if (uwRes.statusCode >= 200 && uwRes.statusCode < 300) {
          final uwBody = utf8.decode(uwRes.bodyBytes).trim();
          if (uwBody.isNotEmpty && uwBody != 'null') {
            final uwMap = jsonDecode(uwBody);
            if (uwMap is Map) {
              for (final entry in uwMap.entries) {
                final v = entry.value;
                if (v is Map) {
                  final wsId = '${v['workspaceId'] ?? entry.key}'.trim();
                  if (wsId.isEmpty || wsId == 'default') continue;
                  final info = WorkspaceInfo.fromJson(
                    Map<String, dynamic>.from(v),
                    fallbackId: wsId,
                    isCurrent: wsId == currentWs,
                  );
                  mapByWs[wsId] = info;
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    final result = mapByWs.values.toList();
    result.sort((a, b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      return a.storeName.compareTo(b.storeName);
    });
    return result;
  }

  /// إنشاء منشأة جديدة كلياً وتوليد `workspaceId` فريد وملف SQLite مستقل ونظيف (`nexora_${workspaceId}.db`)
  /// وتسجيلها في فايربيس باسم البريد الحالي بحالة اشتراك غير مفعل (`unactivated`) حتى يتم الترخيص.
  static Future<String> createAndRegisterNewWorkspace(
    Repo repo, {
    required String backendUrl,
    required String storeName,
    required String phone,
    required String businessActivity,
    required String defaultCurrency,
    String address = '',
    String emailOverride = '',
    String uidOverride = '',
    String displayNameOverride = '',
    String password = '',
    bool isAdditionalWorkspace = false,
  }) async {
    final stBefore = await repo.settings();
    final email = (emailOverride.trim().isNotEmpty
            ? emailOverride
            : (stBefore['account.email'] ?? stBefore['email'] ?? ''))
        .trim()
        .toLowerCase();
    final uid = (uidOverride.trim().isNotEmpty
            ? uidOverride
            : (stBefore['account.uid'] ?? ''))
        .trim();
    final displayName = (displayNameOverride.trim().isNotEmpty
            ? displayNameOverride
            : (stBefore['account.name'] ?? stBefore['sync.deviceName'] ?? ''))
        .trim();

    final prevWsId = repo.requireWorkspaceId.trim();
    final prevStoreName = (stBefore['businessName'] ?? '').trim();
    final prevEmail =
        (stBefore['account.email'] ?? stBefore['email'] ?? '').trim().toLowerCase();
    final isDraftPrev = prevStoreName.isEmpty ||
        prevStoreName == 'متجري' ||
        prevStoreName == 'منشأتي';

    // 0) ممنوع إنشاء مساحة عمل بدون بريد إلكتروني موثق
    if (email.isEmpty || !email.contains('@')) {
      throw StateError(
        'لا يُسمح بإنشاء مساحة عمل سحابية بدون تسجيل الدخول بحساب Google أو بريد إلكتروني موثق.',
      );
    }

    // 0.1) منع إنشاء منشأة ببريد إلكتروني مسجل سابقاً (منشأة واحدة فقط لكل بريد إلكتروني)
    final localEmailMatches = await findLocalWorkspacesOnDevice(
      filterEmail: email,
    );
    final nonDraftLocalEmailMatches = localEmailMatches.where((w) {
      if (isDraftPrev && w.workspaceId == prevWsId) return false;
      return w.workspaceId.isNotEmpty && w.workspaceId != 'default';
    }).toList();
    if (!isAdditionalWorkspace && nonDraftLocalEmailMatches.isNotEmpty) {
      final existingName = nonDraftLocalEmailMatches.first.storeName;
      throw StateError(
        'البريد الإلكتروني ($email) مسجل مسبقاً لمنشأة قائمة'
        '${existingName.isNotEmpty ? ' باسم «$existingName»' : ''} — '
        'يُمنع إنشاء أكثر من منشأة بنفس البريد الإلكتروني.',
      );
    }

    if (backendUrl.isNotEmpty && !isAdditionalWorkspace) {
      final cloudRes = await resolveWorkspaceInCloud(
        backendUrl: backendUrl,
        email: email,
        uid: uid,
      );
      if (cloudRes.found &&
          cloudRes.workspaceId.isNotEmpty &&
          cloudRes.workspaceId != 'default' &&
          !(isDraftPrev && cloudRes.workspaceId == prevWsId)) {
        final existingName = (cloudRes.meta?['storeName'] ??
                cloudRes.meta?['store_name'] ??
                cloudRes.meta?['businessName'] ??
                '')
            .toString()
            .trim();
        throw StateError(
          'البريد الإلكتروني ($email) مسجل مسبقاً لمنشأة قائمة في السحابة'
          '${existingName.isNotEmpty ? ' باسم «$existingName»' : ''} — '
          'يُمنع إنشاء منشأة جديدة ببريد مسجل سابقاً. يمكنك تسجيل الدخول لفتح منشأتك.',
        );
      }
    }

    // 0.2) منع تكرار رقم الهاتف في منشأتين مختلفتين
    final normPhone = normalizePhone(phone);
    // المنشأة الإضافية قد تشارك المالك نفسه هاتفه وبريده — لا تُفحص التكرار.
    if (normPhone.length >= 7 && !isAdditionalWorkspace) {
      final existingPhoneWs = await lookupByPhone(
        backendUrl: backendUrl,
        phone: normPhone,
        excludeWorkspaceId: isDraftPrev ? prevWsId : '',
      );
      if (existingPhoneWs.isNotEmpty) {
        throw StateError(
          'رقم الهاتف المدخل مسجل مسبقاً لمنشأة أخرى ($existingPhoneWs) — يُمنع تكرار رقم الهاتف في منشأتين.',
        );
      }
    }

    // حفظ المنشأة السابقة في السجل المحلي قبل مغادرتها إن كانت مكتملة الإعداد
    if (prevWsId.isNotEmpty && prevWsId != 'default' && !isDraftPrev) {
      await saveWorkspaceToLocalRegistry(
        WorkspaceInfo(
          workspaceId: prevWsId,
          storeName: prevStoreName,
          businessActivity: (stBefore['businessActivity'] ?? '').trim(),
          defaultCurrency: (stBefore['defaultCurrency'] ?? 'YER').trim(),
          phone: (stBefore['phone'] ?? stBefore['whatsapp'] ?? '').trim(),
          ownerEmail: prevEmail,
          role: 'owner',
          isCurrent: false,
        ),
      );
    }

    // حفظ نسخة احتياطية صامتة للمنشأة السابقة (فقط إن كانت منشأة مكتملة وليست مسودة عزل فارغة)
    try {
      if (prevWsId.isNotEmpty && prevWsId != 'default' && !isDraftPrev) {
        if (backendUrl.isNotEmpty) {
          await AutoBackupService.silentWorkspaceBackup(repo, force: true);
        }
        final oldData =
            await repo.exportAll(withImages: false, localOnly: true);
        await FactoryReset.silentBackup(oldData,
            fileName: FactoryReset.kBackupBeforeSwitch);
      }
    } catch (_) {}

    // 1) توليد workspaceId فريد جديد وإغلاق اتصال SQLite السابق وفتح ملف SQLite جديد ونظيف كلياً
    SubscriptionGuard.debugReset();
    final newWsId = generateWorkspaceId();
    if (!repo.hasCustomDatabaseProvider) {
      await DatabaseHelper.instance.close();
      if (prevWsId.isNotEmpty && prevWsId != 'default' && !isDraftPrev) {
        // ضمان نسخ nexora.db إلى nexora_${prevWsId}.db إن كانت المنشأة الأولى على القاعدة الافتراضية
        try {
          await AppDatabase.instance.openForWorkspace(prevWsId);
          await DatabaseHelper.instance.close();
        } catch (_) {}
      }
      await AppDatabase.instance.openForWorkspace(newWsId);
    }
    await repo.isolateForWorkspaceSwitch(
      targetWorkspaceId: newWsId,
      resetOnboarding: false,
    );

    if (isDraftPrev && prevWsId.isNotEmpty && prevWsId != newWsId) {
      try {
        final db = await repo.database;
        await db.delete('workspaces', where: 'id = ?', whereArgs: [prevWsId]);
      } catch (_) {}
    }

    // 2) تثبيت كافة الحقول الإجبارية للمنشأة الجديدة بنسبة 100%
    final cleanStore = storeName.trim();
    final cleanPhone = phone.trim();
    final cleanActivity = businessActivity.trim();
    final cleanCurrency =
        defaultCurrency.trim().isEmpty ? 'YER' : defaultCurrency.trim();
    final cleanAddress = address.trim();

    await repo.setSetting('businessName', cleanStore);
    await repo.setSetting('phone', cleanPhone);
    await repo.setSetting('whatsapp', cleanPhone);
    await repo.setSetting('businessActivity', cleanActivity);
    await repo.setSetting('defaultCurrency', cleanCurrency);
    if (cleanAddress.isNotEmpty) {
      await repo.setSetting('address', cleanAddress);
    }
    await repo.setSetting('account.type', 'enterprise');
    await repo.setSetting('has_completed_onboarding', '1');
    await repo.setSetting('onboardingCompleted', '1');
    await repo.setSetting('subscription.status', 'unactivated');

    // تحديث اسم المنشأة وبريد المالك في جدول workspaces المحلي
    try {
      final db = await repo.database;
      await db.update(
        'workspaces',
        {
          'name': cleanStore,
          if (uid.isNotEmpty) 'owner_google_id': uid,
          if (email.isNotEmpty) 'owner_email': email,
          if (displayName.isNotEmpty) 'owner_name': displayName,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [newWsId],
      );
    } catch (_) {}

    // 3) تثبيت جلسة الحساب والصلاحيات في قاعدة البيانات الجديدة و SharedPreferences
    await FirebaseAuthRest.resetAnonymousSession(repo);
    await FirebaseAuthRest.ensureScopedAnonymous(repo, newWsId);
    await FirebaseAuthRest.initSilentAuth(repo);
    if (uid.isNotEmpty || email.isNotEmpty) {
      await FirebaseAuthRest.saveSession(
        repo,
        FirebaseAccount(
          uid: uid.isNotEmpty ? uid : 'email:${emailToKey(email)}',
          email: email,
          displayName: displayName,
        ),
      );
    }
    if (email.isNotEmpty) {
      await repo.setSetting('account.email', email);
      await repo.setSetting('email', email);
    }
    if (displayName.isNotEmpty) {
      await repo.setSetting('account.name', displayName);
    }
    await repo.checkAndAutoPromoteManager();
    await repo.ensureSelfPermissionRow(roleCode: 'admin');
    await repo.restoreManagerOwnership(syncToCloud: false);

    final wsInfo = WorkspaceInfo(
      workspaceId: newWsId,
      storeName: cleanStore,
      businessActivity: cleanActivity,
      defaultCurrency: cleanCurrency,
      phone: cleanPhone,
      ownerEmail: email,
      role: 'owner',
      isCurrent: true,
    );
    await saveWorkspaceToLocalRegistry(wsInfo);
    await FirebaseAuthRest.saveWorkspaceSessionPrefs(
      workspaceId: newWsId,
      userRole: 'owner',
      businessName: cleanStore,
      ownerEmail: email,
      ownerUid: uid,
      displayName: displayName,
    );

    final cleanPassword = password.trim();
    final pwHash =
        cleanPassword.length >= 6 ? Security.hash(cleanPassword) : '';
    if (pwHash.isNotEmpty) {
      await repo.setSetting('account.passwordHash', pwHash);
    }

    // 4) تسجيل المنشأة في فايربيس باسم هذا البريد وبحالة اشتراك غير مفعل حتى يتم الترخيص
    if (backendUrl.isNotEmpty) {
      final extraMeta = <String, Object?>{
        'storeName': cleanStore,
        if (displayName.isNotEmpty) 'owner_name': displayName,
        'phone': cleanPhone,
        if (cleanAddress.isNotEmpty) 'address': cleanAddress,
        'businessActivity': cleanActivity,
        'defaultCurrency': cleanCurrency,
        'subscriptionStatus': 'unactivated',
        if (pwHash.isNotEmpty) 'password_hash': pwHash,
      };
      if (isAdditionalWorkspace) {
        // (تدقيق بند 12) منشأة إضافية معزولة: تُسجَّل في user_workspaces فقط
        // دون طمس المنشأة الأساسية في emails_index أو فهرس uid — فتبقى
        // المنشأة الأساسية وجهة الدخول الافتراضية للبريد نفسه.
        try {
          final regRoot = backendUrl.replaceAll(RegExp(r'/+$'), '');
          await _authedPatch(
            '$regRoot/workspaces/_registry/user_workspaces/${emailToKey(email)}/${Uri.encodeComponent(newWsId)}.json',
            body: jsonEncode({
              'workspaceId': newWsId,
              'ownerEmail': email,
              'role': 'owner',
              'isAdditional': true,
              ...extraMeta,
              'updated_at': {'.sv': 'timestamp'},
            }),
            timeout: const Duration(seconds: 10),
          );
        } catch (_) {}
      } else {
        try {
          await bind(
            backendUrl: backendUrl,
            uid: uid,
            workspaceId: newWsId,
            email: email,
            phone: cleanPhone,
            extraMeta: extraMeta,
            force: true,
          );
        } catch (_) {}
      }
      try {
        await syncMemberDeviceInWorkspace(
          repo,
          backendUrl: backendUrl,
          workspaceId: newWsId,
          email: email,
          phone: cleanPhone,
          displayName: displayName.isNotEmpty ? displayName : cleanStore,
          isOwner: true,
        );
      } catch (_) {}
      try {
        await DeviceRegistry.upsertBinding(repo,
            backendUrl: backendUrl, force: true);
      } catch (_) {}
      try {
        await SubscriptionGuard.initUnactivatedSubscription(
          repo,
          backendUrl: backendUrl,
          workspaceId: newWsId,
        );
      } catch (_) {}
      await repo.setSetting('cloudWorkspaceProvisioned', '1');
      try {
        await AutoBackupService.silentWorkspaceBackup(repo, force: true);
      } catch (_) {}
    }

    return newWsId;
  }

  /// التبديل الآمن بين منشآت المستخدم دون تداخل حسابات أو عمليات المنشأتين مع بعضهما.
  static Future<bool> switchToExistingWorkspace(
    Repo repo, {
    required String backendUrl,
    required String targetWorkspaceId,
  }) async {
    final target = targetWorkspaceId.trim();
    if (target.isEmpty || target == 'default') return false;
    final currentWs = repo.requireWorkspaceId;
    if (target == currentWs) return true;

    final stBefore = await repo.settings();
    final prevStoreName = (stBefore['businessName'] ?? '').trim();
    final prevEmail = (stBefore['account.email'] ?? stBefore['email'] ?? '')
        .trim()
        .toLowerCase();
    final prevUid = (stBefore['account.uid'] ?? '').trim();
    final prevDisplayName =
        (stBefore['account.name'] ?? stBefore['sync.deviceName'] ?? '').trim();
    final prevMode = await repo.workspaceMode();
    final wasOwner = await repo.isWorkspaceOwner();
    final isPrevConfigured = prevMode != 'member' &&
        wasOwner &&
        prevStoreName.isNotEmpty &&
        prevStoreName != 'متجري' &&
        prevStoreName != 'منشأتي';

    // 1) حفظ المنشأة الحالية في السجل المحلي وأخذ نسخة احتياطية صامتة قبل مغادرتها (للمالك فقط)
    if (currentWs.isNotEmpty && currentWs != 'default' && isPrevConfigured) {
      await saveWorkspaceToLocalRegistry(
        WorkspaceInfo(
          workspaceId: currentWs,
          storeName: prevStoreName,
          businessActivity: (stBefore['businessActivity'] ?? '').trim(),
          defaultCurrency: (stBefore['defaultCurrency'] ?? 'YER').trim(),
          phone: (stBefore['phone'] ?? stBefore['whatsapp'] ?? '').trim(),
          ownerEmail: prevEmail,
          role: 'owner',
          isCurrent: false,
        ),
      );
    }
    try {
      if (isPrevConfigured) {
        if (backendUrl.isNotEmpty) {
          await AutoBackupService.silentWorkspaceBackup(repo, force: true);
        }
        final currentData =
            await repo.exportAll(withImages: false, localOnly: true);
        await FactoryReset.silentBackup(currentData,
            fileName: FactoryReset.kBackupBeforeSwitch);
      }
    } catch (_) {}

    // 2) إغلاق اتصال SQLite الحالي وفتح ملف قاعدة البيانات المعزول للمنشأة المستهدفة (nexora_${target}.db)
    SubscriptionGuard.debugReset();
    await DatabaseHelper.instance.close();
    if (prevMode == 'member' &&
        currentWs.isNotEmpty &&
        currentWs != 'default' &&
        currentWs != target) {
      await removeWorkspaceFromLocalRegistry(currentWs, deleteDbFile: true);
    } else if (currentWs.isNotEmpty &&
        currentWs != 'default' &&
        isPrevConfigured) {
      try {
        await AppDatabase.instance.openForWorkspace(currentWs);
        await DatabaseHelper.instance.close();
      } catch (_) {}
    }
    await AppDatabase.instance.openForWorkspace(target);
    repo.debugSetWorkspaceId(target);

    // صمام أمان حاسم: إذا تبيّن أن المنشأة المستهدفة هي قاعدة بيانات عضو منضم، يُحظر فتحها كمنشأة مالك!
    final targetMode = await repo.workspaceMode();
    if (targetMode == 'member') {
      await removeWorkspaceFromLocalRegistry(target, deleteDbFile: true);
      await repo.isolateForWorkspaceSwitch(resetOnboarding: true);
      return false;
    }

    await repo.setSetting('sync.workspaceId', target);

    // قراءة الهوية الخاصة بالمنشأة المستهدفة نفسها (وليس المنشأة السابقة!) لمنع خلط البريد بين المنشآت
    final stTarget = await repo.settings();
    String targetEmail =
        (stTarget['account.email'] ?? stTarget['email'] ?? '')
            .trim()
            .toLowerCase();
    String targetUid = (stTarget['account.uid'] ?? '').trim();
    String targetDisplayName =
        (stTarget['account.name'] ?? stTarget['sync.deviceName'] ?? '').trim();

    try {
      final dbTarget = await repo.database;
      final wsRows = await dbTarget.query(
        'workspaces',
        where: 'id = ?',
        whereArgs: [target],
        limit: 1,
      );
      if (wsRows.isNotEmpty) {
        if (targetEmail.isEmpty) {
          targetEmail =
              '${wsRows.first['owner_email'] ?? ''}'.trim().toLowerCase();
        }
        if (targetUid.isEmpty) {
          targetUid = '${wsRows.first['owner_google_id'] ?? ''}'.trim();
        }
        if (targetDisplayName.isEmpty) {
          targetDisplayName = '${wsRows.first['owner_name'] ?? ''}'.trim();
        }
      }
    } catch (_) {}

    if (targetEmail.isEmpty) {
      try {
        final localSaved =
            await findLocalWorkspacesOnDevice(currentWorkspaceId: target);
        for (final w in localSaved) {
          if (w.workspaceId == target && w.ownerEmail.isNotEmpty) {
            targetEmail = w.ownerEmail.trim().toLowerCase();
            break;
          }
        }
      } catch (_) {}
    }

    if (targetEmail.isEmpty) targetEmail = prevEmail;
    if (targetUid.isEmpty && targetEmail == prevEmail) targetUid = prevUid;
    if (targetUid.isEmpty && targetEmail.isNotEmpty) {
      targetUid = 'email:${emailToKey(targetEmail)}';
    }
    if (targetDisplayName.isEmpty) targetDisplayName = prevDisplayName;

    final account = FirebaseAccount(
      uid: targetUid,
      email: targetEmail,
      displayName: targetDisplayName,
    );

    // 3) إذا كانت قاعدة البيانات المعزولة للمنشأة المستهدفة فارغة محلياً، نجلب بياناتها من السحابة
    final localAccounts =
        await repo.accounts(includeArchived: true, includeDeleted: true);
    final hasLocalSetup =
        (stTarget['businessName'] ?? '').trim().isNotEmpty &&
            (stTarget['businessName'] ?? '').trim() != 'متجري' &&
            (stTarget['businessName'] ?? '').trim() != 'منشأتي';

    if (localAccounts.isEmpty && !hasLocalSetup && backendUrl.isNotEmpty) {
      await _switchWorkspace(
        repo,
        backendUrl: backendUrl,
        account: account,
        fromWorkspaceId: target,
        toWorkspaceId: target,
      );
    } else if (backendUrl.isNotEmpty) {
      try {
        await CloudFirebaseTransport(
          repo: repo,
          dbProvider: () => repo.database,
          backendUrl: backendUrl,
          workspaceId: target,
          idTokenProvider: () => FirebaseAuthRest.cloudIdToken(),
        ).pull(forceFullSync: true).timeout(const Duration(seconds: 20));
      } catch (_) {}
    }

    final stAfter = await repo.settings();
    final finalEmail = (stAfter['account.email'] ??
            stAfter['email'] ??
            targetEmail)
        .trim()
        .toLowerCase();
    final finalUid = (stAfter['account.uid'] ?? targetUid).trim();
    final finalDisplayName =
        (stAfter['account.name'] ?? targetDisplayName).trim();
    final finalAccount = FirebaseAccount(
      uid: finalUid.isNotEmpty
          ? finalUid
          : (finalEmail.isNotEmpty ? 'email:${emailToKey(finalEmail)}' : ''),
      email: finalEmail,
      displayName: finalDisplayName,
    );

    if (finalAccount.uid.isNotEmpty || finalAccount.email.isNotEmpty) {
      await FirebaseAuthRest.saveSession(repo, finalAccount);
    }
    if (finalEmail.isNotEmpty) {
      await repo.setSetting('account.email', finalEmail);
      await repo.setSetting('email', finalEmail);
    }
    await repo.setSetting('has_completed_onboarding', '1');
    await repo.setSetting('onboardingCompleted', '1');
    await repo.setSetting('cloudWorkspaceProvisioned', '1');
    await repo.checkAndAutoPromoteManager();
    await repo.ensureSelfPermissionRow(roleCode: 'admin');

    final storeName = (stAfter['businessName'] ?? 'منشأة ($target)').trim();
    await FirebaseAuthRest.saveWorkspaceSessionPrefs(
      workspaceId: target,
      userRole: 'owner',
      businessName: storeName,
      ownerEmail: finalEmail,
      ownerUid: finalUid,
      displayName: finalDisplayName,
    );
    await saveWorkspaceToLocalRegistry(
      WorkspaceInfo(
        workspaceId: target,
        storeName: storeName,
        businessActivity: (stAfter['businessActivity'] ?? '').trim(),
        defaultCurrency: (stAfter['defaultCurrency'] ?? 'YER').trim(),
        phone: (stAfter['phone'] ?? stAfter['whatsapp'] ?? '').trim(),
        ownerEmail: finalEmail,
        role: 'owner',
        isCurrent: true,
      ),
    );

    // 4) تحديث ربط الجهاز بالمنشأة النشطة حالياً وجلب حالة اشتراكها الفعلية من السحابة فوراً
    if (backendUrl.isNotEmpty) {
      try {
        await DeviceRegistry.upsertBinding(repo,
            backendUrl: backendUrl, force: true);
      } catch (_) {}
      try {
        final devId = await ensureDeviceId(repo);
        final devKey = devId.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
        final root = _trimSlashes(backendUrl);
        await _authedPatch(
          '$root/workspaces/_registry/device_index/${Uri.encodeComponent(devKey)}.json',
          body: jsonEncode({
            'workspace_id': target,
            'workspaceId': target,
            'device_id': devId,
            'store_name': storeName,
            if (finalEmail.isNotEmpty) 'owner_email': finalEmail,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          }),
          timeout: const Duration(seconds: 8),
        );
      } catch (_) {}
      try {
        await SubscriptionGuard.check(
          repo,
          backendUrl: backendUrl,
          workspaceId: target,
          force: true,
        );
      } catch (_) {}
    }
    return true;
  }

  /// حذف منشأة فعلياً وبشكل صريح وقاطع من السحابة ومن الجهاز (قاعدة البيانات المحلية والسجل المحلي).
  static Future<void> deleteWorkspaceRegistration(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    String ownerEmail = '',
    String phone = '',
    bool deleteLocalDbFile = true,
  }) async {
    final cleanWs = workspaceId.trim();
    if (cleanWs.isEmpty || cleanWs == 'default') return;

    final st = await repo.settings();
    final email = (ownerEmail.trim().isNotEmpty
            ? ownerEmail
            : (st['account.email'] ?? st['email'] ?? ''))
        .trim()
        .toLowerCase();
    var resolvedPhone = phone.trim();
    if (resolvedPhone.isEmpty) {
      try {
        final localList = await findLocalWorkspacesOnDevice();
        for (final w in localList) {
          if (w.workspaceId.trim() == cleanWs && w.phone.trim().isNotEmpty) {
            resolvedPhone = w.phone.trim();
            break;
          }
        }
      } catch (_) {}
    }

    // 1) حذف شامل وصريح من السحابة (العقدة الجذرية للمنشأة + التراخيص + الفهارس)
    if (backendUrl.trim().isNotEmpty) {
      final root = _trimSlashes(backendUrl);
      final encWs = Uri.encodeComponent(cleanWs);
      final paths = <String>[
        '$root/workspaces/$encWs.json',
        '$root/workspaces/_registry/subscriptions_index/$encWs.json',
        '$root/workspaces/_registry/license_hub/licenses/$encWs.json',
        '$root/support_chats/$encWs.json',
      ];
      if (email.isNotEmpty) {
        final emailKey = emailToKey(email);
        paths.add(
            '$root/workspaces/_registry/user_workspaces/$emailKey/$encWs.json');
        // (حماية الفهرس السحابي) يُمنع منعاً باتاً مسح مؤشر البريد الرئيسي
        // (emails_index) عند حذف منشأة: هذا المؤشر هو ما يهتدي به تسجيل
        // الدخول اللاحق إلى منشأة البريد المعتمدة في السحابة، ومسحه كان
        // يفتح الباب لتوليد منشآت وهمية بديلة عند الدخول التالي بحساب
        // Google. يُحذف فقط إدخال هذه المنشأة من قائمة منشآت البريد أعلاه.
      }
      final normPhone = normalizePhone(resolvedPhone);
      if (normPhone.length >= 7) {
        final phoneKey = phoneToKey(normPhone);
        if (phoneKey.isNotEmpty) {
          paths.add('$root/workspaces/_registry/phones_index/$phoneKey.json');
        }
      }
      for (final p in paths) {
        try {
          await _authedDelete(p, timeout: const Duration(seconds: 10));
        } catch (_) {}
      }
    }

    // 2) إزالة من جدول workspaces في قاعدة البيانات المفتوحة حالياً (إن لم تكن هي نفس القاعدة المراد حذفها)
    try {
      final db = await repo.database;
      await db.delete('workspaces', where: 'id = ?', whereArgs: [cleanWs]);
    } catch (_) {}

    // 3) إزالة من السجل المحلي (SharedPreferences) وحذف ملف nexora_${wsId}.db من الجهاز
    await removeWorkspaceFromLocalRegistry(
      cleanWs,
      deleteDbFile: deleteLocalDbFile,
    );
  }
}
