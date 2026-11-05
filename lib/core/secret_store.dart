// (دفعة 57) تعمية أسرار الأجهزة (devices.auth_secret) عند التخزين.
//
// المبدأ: القيمة تبقى نصاً صريحاً في الذاكرة وعلى بروتوكول LAN (القرين
// يحتاجها كما هي)، لكنها لا تلمس قرص SQLite إلا معمّاة عبر TokenCipher
// (enc1:base64 — مفتاح 32 بايت خارج قاعدة البيانات في documents/.nexora_key).
// النتيجة: نسخة قاعدة بيانات مسرّبة/مُصدَّرة لا تكشف أسرار مصادقة الأقران.
//
// التعمية حتمية (نفس النص → نفس الناتج على نفس الجهاز) فمقارنات
// `WHERE auth_secret = ?` تعمل بتمرير الشكلين معاً (صريح قديم + معمّى)
// — توافق خلفي كامل مع الصفوف المخزنة قبل هذه الدفعة.
//
// في بيئة اختبارات VM (بلا path_provider) يعمل الصنف كهوية شفافة.
import 'dart:convert';

import 'token_cipher.dart';

class SecretStore {
  /// للتخزين: يعمّي السر قبل كتابته في قاعدة البيانات باستخدام متجه تهيئة مشتق (SIV)
  /// عبر HMAC-SHA256 لضمان أمان التعمية مع بقاء إمكانية المطابقة الحتمية محلياً.
  static Future<String> protect(String plain) =>
      TokenCipher.protect(plain, deterministic: true);

  /// للاستخدام: يفك التعمية عند القراءة (القيم القديمة الصريحة و enc1 و enc2 تُفك جميعاً).
  static Future<String> reveal(String stored) => TokenCipher.reveal(stored);

  /// للمقارنة في WHERE: يعيد الأشكال المقبولة لسرّ وارد صريح —
  /// [الصريح كما ورد، المعمّى بصيغة enc2 الحتمية، المعمّى بصيغة enc1 التوافقية].
  static Future<List<String>> matchForms(String plain) async {
    final p2 = await protect(plain);
    if (p2 == plain) return [plain, plain];
    final p1 = await TokenCipher.protectLegacyV1(plain);
    return <String>{plain, p2, p1}.toList();
  }

  /// تحقق زمني ثابت (Constant-Time Comparison) من تطابق السر الصريح مع القيمة المخزنة
  /// (سواء كانت مشفرة بصيغة enc2 عشوائية/حتمية، أو enc1، أو نصاً صريحاً).
  static Future<bool> verify(String plain, String stored) async {
    if (plain.isEmpty || stored.isEmpty) return false;
    final revealed = await reveal(stored);
    final a = utf8.encode(plain);
    final b = utf8.encode(revealed);
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
