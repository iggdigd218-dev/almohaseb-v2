// (استرداد بصمة العتاد) فهرس الأجهزة السحابي — Device→Workspace Registry.
//
// المسار: /device_index/{fpHash} = { workspaceId, role, device_id, updated_at }
//
// الغرض: بصمة العتاد ثابتة حتى بعد حذف التطبيق أو مسح بياناته — فتصبح
// مفتاح استرداد دائماً:
//  - كل جهاز يُسجَّل ببصمته مربوطاً بمساحته ودوره (owner/member).
//  - عند إقلاع تثبيت جديد نظيف: نفحص الفهرس؛ وجدنا سجلاً؟ نستعيد
//    المساحة والدور والبيانات (من النسخة الصامتة) تلقائياً وبصمت.
//  - الدور محفوظ: المدير يعود مديراً لمؤسسته نفسها، والعضو عضواً —
//    ولا يُعطى دور المدير في أي مساحة أخرى غير مساحته المسجلة.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../repository.dart';
import 'device_id.dart';
import 'firebase_auth_service.dart';
import 'subscription_guard.dart';

class DeviceRegistryRecord {
  final String workspaceId;
  final String role; // 'owner' | 'member'
  final String deviceId;
  const DeviceRegistryRecord({
    required this.workspaceId,
    required this.role,
    required this.deviceId,
  });
  bool get isOwner => role == 'owner';
}

class DeviceRegistry {
  DeviceRegistry._();

  // ملاحظة قواعد الأمان: الجذر /device_index محجوب كتابةً في قواعد
  // القاعدة الحالية، بينما /workspaces/** مفتوح — لذا يسكن الفهرس تحت
  // عقدة خدمية داخل workspaces (ليست مساحة عمل حقيقية).
  static String _indexPath(String base, String fp) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'device_index/${Uri.encodeComponent(fp)}.json';

  /// بصمة العتاد المجزأة لهذا الجهاز (مفتاح الفهرس الثابت).
  static Future<String> fingerprintKey(Repo repo) async {
    final devId = await ensureDeviceId(repo);
    final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
    return SubscriptionGuard.fingerprintHash(raw);
  }

  /// (F-1a) توكن موثّق أفضل جهد لطلبات الفهرس — القواعد تشترط
  /// auth != null فالطلب العاري يُرفض 401.
  static Future<String?> _token() async {
    var t = FirebaseAuthRest.cachedIdToken;
    if (t == null || t.isEmpty) {
      try {
        t = await FirebaseAuthRest.cloudIdToken();
      } catch (_) {}
    }
    return (t != null && t.isNotEmpty) ? t : null;
  }

  static Uri _authedUri(String url, String? token) {
    final uri = Uri.parse(url);
    if (token == null) return uri;
    final q = Map<String, String>.from(uri.queryParameters)..['auth'] = token;
    return uri.replace(queryParameters: q);
  }

  /// طلب موثّق مع تجديد توكن واحد عند 401/403 — الاستثناءات تُلقى
  /// للمستدعي (وكل المستدعين هنا best-effort داخل try/catch).
  static Future<http.Response?> _authedCall(
    String url,
    Future<http.Response> Function(Uri uri) call,
  ) async {
    final token = await _token();
    var res = await call(_authedUri(url, token));
    if (token != null &&
        (res.statusCode == 401 || res.statusCode == 403)) {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh.isNotEmpty) {
        res = await call(_authedUri(url, fresh));
      }
    }
    return res;
  }

  /// قراءة سجل هذا الجهاز من الفهرس — null إن لم يوجد أو تعذرت الشبكة.
  static Future<DeviceRegistryRecord?> lookup({
    required String backendUrl,
    required String fingerprint,
  }) async {
    try {
      // (F-1a) قراءة موثّقة — كان الطلب عارياً فيُرفض 401 حسب القواعد
      // فيفقد الجهاز حقه في الاسترداد بصمته رغم أن الفهرس يعمل.
      final res = await _authedCall(
        _indexPath(backendUrl, fingerprint),
        (u) => http.get(u).timeout(const Duration(seconds: 15)),
      );
      if (res == null) return null;
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.isEmpty || body == 'null') return null;
      final m = jsonDecode(body);
      if (m is! Map) return null;
      final ws = '${m['workspaceId'] ?? ''}'.trim();
      if (ws.isEmpty) return null;
      final role = '${m['role'] ?? ''}' == 'owner' ? 'owner' : 'member';
      return DeviceRegistryRecord(
        workspaceId: ws,
        role: role,
        deviceId: '${m['device_id'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// كتابة/تحديث ربط بصمة هذا الجهاز بمساحته ودوره الحاليين.
  ///
  /// 🔒 حماية الدور: السجل القائم بدور owner لا يُخفَّض ولا تُبدَّل
  /// مساحته تلقائياً أبداً — المدير مربوط بمؤسسته حتى يتنازل صراحة
  /// (transferOwnership يمرر force=true بعد التنازل الصريح).
  static Future<void> upsertBinding(
    Repo repo, {
    required String backendUrl,
    bool force = false,
  }) async {
    try {
      final fp = await fingerprintKey(repo);
      final devId = await ensureDeviceId(repo);
      final ws = repo.requireWorkspaceId;
      final mode = await repo.workspaceMode();
      final isOwner = await repo.isWorkspaceOwner();
      final role = (mode == 'member' && !isOwner) ? 'member' : 'owner';
      // (3.71.0 — نظام صارم) ربط المالك في الفهرس السحابي يشترط التسجيل
      // بالبريد (حساب Google): هوية مجهولة لا تُسجَّل مالكة لمساحة —
      // يمنع اختلاق مساحات أشباح. ربط العضو غير مشروط (حق الاسترداد).
      final stSettings = await repo.settings();
      final ownerEmail =
          (stSettings['account.email'] ?? stSettings['email'] ?? '')
              .trim()
              .toLowerCase();
      final storeName = (stSettings['businessName'] ?? '').trim();
      if (role == 'owner') {
        if (ownerEmail.isEmpty) return;
      }
      if (!force) {
        final existing =
            await lookup(backendUrl: backendUrl, fingerprint: fp);
        if (existing != null && existing.isOwner) {
          // مالك مسجل: لا خفض دور ولا تغيير مساحة تلقائيين.
          if (role != 'owner' || existing.workspaceId != ws) return;
        }
      }
      // (F-1a) كتابة موثّقة — الجذر يُكتب بموجب القواعد للعضو الموثّق
      // فقط؛ الطلب العاري 401 فيضيع حق الاسترداد بصمت.
      final res = await _authedCall(
        _indexPath(backendUrl, fp),
        (u) => http
            .put(
              u,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'workspaceId': ws,
                'workspace_id': ws,
                'role': role,
                'device_id': devId,
                if (ownerEmail.isNotEmpty) 'owner_email': ownerEmail,
                if (storeName.isNotEmpty) 'store_name': storeName,
                'updated_at': {'.sv': 'timestamp'},
              }),
            )
            .timeout(const Duration(seconds: 15)),
      );
      if (res == null || res.statusCode < 200 || res.statusCode >= 300) {
        return;
      }
    } catch (_) {
      // أفضل جهد — الدورة القادمة تعيد المحاولة.
    }
  }

  /// (انضمام عضو) تسجيل بصمة العضو المنضم مربوطة بمساحة المجموعة.
  static Future<void> bindAsMember(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    try {
      final fp = await fingerprintKey(repo);
      final devId = await ensureDeviceId(repo);
      final existing = await lookup(backendUrl: backendUrl, fingerprint: fp);
      // 🔒 مدير مؤسسة أخرى لا يُسجَّل عضواً في مجموعة جديدة إلا إذا كانت
      // مساحته هي نفسها (لا وجود لمديرَين — عليه استرجاع مؤسسته أولاً
      // أو التنازل صراحة). التطبيق يسمح بالانضمام؛ الفهرس يحفظ حقه.
      if (existing != null &&
          existing.isOwner &&
          existing.workspaceId != workspaceId) {
        return;
      }
      // (F-1a) كتابة موثّقة — نفس نمط upsertBinding.
      await _authedCall(
        _indexPath(backendUrl, fp),
        (u) => http
            .put(
              u,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'workspaceId': workspaceId,
                'role': 'member',
                'device_id': devId,
                'updated_at': {'.sv': 'timestamp'},
              }),
            )
            .timeout(const Duration(seconds: 15)),
      );
    } catch (_) {}
  }
}
