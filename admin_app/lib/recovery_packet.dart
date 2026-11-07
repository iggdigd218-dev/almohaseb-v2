// بروتوكول حزمة استعادة كلمة المرور — **مصدر حقيقة واحد** للعميل وتطبيق الإدارة.
//
// (إصلاح R-01/R-02) قبل هذا الملف كان العميل يبني مظروفًا بمفاتيح
// `{protocol, op, pkt, chk}` بينما تطبيق الإدارة يقرأ
// `{payload_b64, sig_sha256}` — فلم يكن التحقق الآلي ينجح أبدًا.
// وكان «التوقيع» مجرد sha256 لبيانات الحزمة نفسها بلا أي سرّ ⇒ قابل للتزوير.
//
// الآن: مظروف واحد بمفاتيح موحّدة + توقيع **HMAC-SHA256** بمفتاح مشترك،
// ويُتحقق منه في الطرفين بنفس الدالة ونفس الترتيب.
//
// ملاحظة أمنية: المفتاح المشترك مُضمَّن في التطبيقين (لا خادم بعد).
// عند توفر Cloud Function يجب نقله إلى الخادم وحده وإبقاء العميل يرسل
// الحزمة بلا توقيع — انظر تقرير التدقيق.
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// حزمة استعادة كلمة المرور الموقّعة — V2.
class RecoveryPacket {
  RecoveryPacket._({
    required this.phone,
    required this.phoneKey,
    required this.deviceId,
    required this.deviceFingerprint,
    required this.email,
    required this.workspaceId,
    required this.storeName,
    required this.timestampMs,
    required this.nonce,
    required this.payloadB64,
    required this.signature,
  });

  // ── ثوابت البروتوكول (يجب أن تطابق حرفيًا نسخة تطبيق الإدارة) ──
  static const String protocolId = 'NEXORA_AI_CORE_RPC';
  static const int protocolVersion = 2;
  static const String opAuthReset = '0x7F_AUTH_RESET';
  static const String cmdPasswordRecovery = '0x7F_PWD_RECOVERY_REQ';
  static const String hmacKey = 'NX-RECOVERY-RPC-V2-HMAC-2026-8f41c2';

  /// أقصى عمر مسموح للحزمة (منع إعادة استخدام حزمة قديمة).
  static const Duration maxAge = Duration(days: 7);

  // ── مفاتيح المظروف ──
  static const String kEnvelopeProtocol = 'protocol';
  static const String kEnvelopeVersion = 'version';
  static const String kEnvelopeOp = 'op';
  static const String kEnvelopePayload = 'payload_b64';
  static const String kEnvelopeSignature = 'sig_hmac_sha256';

  // ── مفاتيح الحمولة ──
  static const String kCmd = 'cmd';
  static const String kVersion = 'v';
  static const String kPhone = 'phone';
  static const String kPhoneKey = 'phone_key';
  static const String kDeviceId = 'device_id';
  static const String kDeviceFingerprint = 'device_fingerprint';
  static const String kEmail = 'email';
  static const String kWorkspaceId = 'workspace_id';
  static const String kStoreName = 'store_name';
  static const String kTimestamp = 'ts';
  static const String kNonce = 'nonce';

  final String phone;
  final String phoneKey;
  final String deviceId;
  final String deviceFingerprint;
  final String email;
  final String workspaceId;
  final String storeName;
  final int timestampMs;
  final String nonce;

  /// الحمولة المُرمَّزة (base64url) كما وُقِّعت بالضبط.
  final String payloadB64;
  final String signature;

  bool get hasPhone => phone.isNotEmpty;
  bool get hasEmail => email.contains('@');

  /// هل الحزمة حديثة بما يكفي؟
  bool get isFresh =>
      DateTime.now().millisecondsSinceEpoch - timestampMs <= maxAge.inMilliseconds;

  /// بناء الحزمة وتوقيعها.
  static RecoveryPacket build({
    required String phone,
    String phoneKey = '',
    required String deviceId,
    required String deviceFingerprint,
    String email = '',
    String workspaceId = '',
    String storeName = '',
    int? timestampMs,
    String? nonce,
  }) {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final payload = <String, Object?>{
      kCmd: cmdPasswordRecovery,
      kVersion: protocolVersion,
      kPhone: phone.trim(),
      if (phoneKey.trim().isNotEmpty) kPhoneKey: phoneKey.trim(),
      kDeviceId: deviceId.trim(),
      kDeviceFingerprint: deviceFingerprint.trim(),
      if (email.trim().isNotEmpty) kEmail: email.trim().toLowerCase(),
      if (workspaceId.trim().isNotEmpty) kWorkspaceId: workspaceId.trim(),
      if (storeName.trim().isNotEmpty) kStoreName: storeName.trim(),
      kTimestamp: ts,
      kNonce: (nonce ?? '').trim().isNotEmpty ? nonce!.trim() : _nonceFor(ts),
    };
    final payloadB64 = base64Url.encode(utf8.encode(jsonEncode(payload)));
    return RecoveryPacket._(
      phone: '${payload[kPhone]}',
      phoneKey: '${payload[kPhoneKey] ?? ''}',
      deviceId: '${payload[kDeviceId]}',
      deviceFingerprint: '${payload[kDeviceFingerprint]}',
      email: '${payload[kEmail] ?? ''}',
      workspaceId: '${payload[kWorkspaceId] ?? ''}',
      storeName: '${payload[kStoreName] ?? ''}',
      timestampMs: ts,
      nonce: '${payload[kNonce]}',
      payloadB64: payloadB64,
      signature: signPayload(payloadB64),
    );
  }

  /// المظروف الكامل كخريطة JSON (نفس المفاتيح في الطرفين).
  Map<String, Object?> toEnvelopeMap() => <String, Object?>{
        kEnvelopeProtocol: protocolId,
        kEnvelopeVersion: protocolVersion,
        kEnvelopeOp: opAuthReset,
        kEnvelopePayload: payloadB64,
        kEnvelopeSignature: signature,
      };

  /// النص المرسل فعليًا (كتلة كود يقرأها المشرف ويلصقها في تطبيق الإدارة).
  String encode() => '```nexora-ai-rpc\n${jsonEncode(toEnvelopeMap())}\n```';

  /// نص المظروف وحده بلا أسوار الكود.
  String encodeEnvelopeJson() => jsonEncode(toEnvelopeMap());

  /// رسالة التوقيع القانونية: جميع حقول المظروف بهذا الترتيب.
  static String signingMessage(String payloadB64) =>
      '$protocolId|$protocolVersion|$opAuthReset|$payloadB64';

  /// HMAC-SHA256 (hex) على الحمولة المرمّزة بـbase64url.
  static String signPayload(String payloadB64) {
    final hmac = Hmac(sha256, utf8.encode(hmacKey));
    return hmac.convert(utf8.encode(signingMessage(payloadB64))).toString();
  }

  /// يستخرج أول كتلة JSON من نص حر (رسالة واتساب مثلًا).
  static Map<String, dynamic>? extractEnvelope(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final fence = RegExp(
      r'```(?:nexora-ai-rpc|json)?\s*(\{[\s\S]*?\})\s*```',
      multiLine: true,
    ).firstMatch(text);
    final candidate = fence != null ? fence.group(1)! : text;

    Map<String, dynamic>? asMap(String s) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
      return null;
    }

    final direct = asMap(candidate);
    if (direct != null) return direct;
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) return asMap(text.substring(start, end + 1));
    return null;
  }

  /// فك الحزمة والتحقق من توقيعها. يرجع `null` لأي حزمة غير صالحة أو مزوّرة.
  static RecoveryPacket? decode(String raw) {
    final envelope = extractEnvelope(raw);
    if (envelope == null) return null;

    final protocol = '${envelope[kEnvelopeProtocol] ?? ''}'.trim();
    final op = '${envelope[kEnvelopeOp] ?? ''}'.trim();
    final payloadB64 = '${envelope[kEnvelopePayload] ?? ''}'.trim();
    final sig = '${envelope[kEnvelopeSignature] ?? ''}'.trim().toLowerCase();
    if (protocol != protocolId) return null;
    if (op != opAuthReset) return null;
    if (payloadB64.isEmpty || sig.isEmpty) return null;

    // التوقيع يُتحقق **قبل** أي تفسير للحمولة.
    if (!constantTimeEquals(signPayload(payloadB64), sig)) return null;

    try {
      final payloadJson = utf8.decode(base64Url.decode(payloadB64));
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return null;
      final payload = Map<String, dynamic>.from(decoded);
      if ('${payload[kCmd] ?? ''}' != cmdPasswordRecovery) return null;
      final ts = payload[kTimestamp];
      final tsMs = ts is int ? ts : int.tryParse('${ts ?? ''}') ?? 0;
      if (tsMs <= 0) return null;
      return RecoveryPacket._(
        phone: '${payload[kPhone] ?? ''}'.trim(),
        phoneKey: '${payload[kPhoneKey] ?? ''}'.trim(),
        deviceId: '${payload[kDeviceId] ?? ''}'.trim(),
        deviceFingerprint: '${payload[kDeviceFingerprint] ?? ''}'.trim(),
        email: '${payload[kEmail] ?? ''}'.trim().toLowerCase(),
        workspaceId: '${payload[kWorkspaceId] ?? ''}'.trim(),
        storeName: '${payload[kStoreName] ?? ''}'.trim(),
        timestampMs: tsMs,
        nonce: '${payload[kNonce] ?? ''}'.trim(),
        payloadB64: payloadB64,
        signature: sig,
      );
    } catch (_) {
      return null;
    }
  }

  /// مقارنة زمنية ثابتة (تمنع تسريب التوقيع عبر قياس الزمن).
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String _nonceFor(int ts) =>
      '${ts.toRadixString(36)}${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}
