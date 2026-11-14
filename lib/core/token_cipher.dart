// تعمية التوكنات الحساسة عند التخزين (id_token وأسرار مشابهة).
//
// المفتاح عشوائي 32 بايت يُولَّد مرة واحدة ويُحفظ في ملف خاص خارج قاعدة
// البيانات (documents/.nexora_key). النتيجة: أي نسخة من ملف قاعدة البيانات
// (نسخ احتياطي مُصدَّر، سحب الملف من الجهاز) لا تكشف التوكن بنص صريح —
// فك التعمية يتطلب ملف المفتاح الذي لا يغادر الجهاز أبداً.
//
// الصيغة المخزنة: `enc1:<base64>` حيث المحتوى XOR مع keystream مشتق من
// المفتاح عبر SHA-256 (counter mode مبسّط). ليست بديلاً عن Keystore العتادي،
// لكنها تفصل المفتاح عن البيانات وهو الهدف العملي هنا.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class TokenCipher {
  static const _prefixV1 = 'enc1:';
  static const _prefixV2 = 'enc2:';
  static const _prefixV3 = 'enc3:';
  static const _nonceLength = 16;
  static const _macByteLength = 16;
  static Uint8List? _cachedKey;
  static Uint8List? _ephemeralFallbackKey;
  static Future<Uint8List>? _loadingKey;

  static Uint8List _getOrCreateEphemeralKey() {
    if (_ephemeralFallbackKey != null) return _ephemeralFallbackKey!;
    final rnd = Random.secure();
    _ephemeralFallbackKey =
        Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    return _ephemeralFallbackKey!;
  }

  static Future<Uint8List> _key() async {
    if (_cachedKey != null) return _cachedKey!;
    if (_loadingKey != null) return _loadingKey!;
    final future = _loadOrCreateKey();
    _loadingKey = future;
    try {
      return await future;
    } finally {
      _loadingKey = null;
    }
  }

  static Future<Uint8List> _loadOrCreateKey() async {
    if (_cachedKey != null) return _cachedKey!;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/.nexora_key');
      if (await f.exists()) {
        final b = await f.readAsBytes();
        if (b.length >= 32) {
          _cachedKey = Uint8List.fromList(b.sublist(0, 32));
          return _cachedKey!;
        }
      }
      final rnd = Random.secure();
      final fresh =
          Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
      await f.writeAsBytes(fresh, flush: true);
      try {
        if (!Platform.isWindows) {
          await Process.run('chmod', ['600', f.path]);
        }
      } catch (_) {}
      _cachedKey = fresh;
      return fresh;
    } catch (_) {
      // في بيئات الاختبار غير المهيأة نستخدم مفتاحاً عشوائياً آمناً في الذاكرة
      // بدلاً من إرجاع النص الصريح دون تشفير.
      _cachedKey = _getOrCreateEphemeralKey();
      return _cachedKey!;
    }
  }

  static (Uint8List encKey, Uint8List macKey) _deriveSubKeys(
    Uint8List masterKey,
    Uint8List nonce,
  ) {
    final encKey = Uint8List.fromList(
      Hmac(sha256, masterKey)
          .convert([...utf8.encode('enc3-cipher'), ...nonce])
          .bytes,
    );
    final macKey = Uint8List.fromList(
      Hmac(sha256, masterKey)
          .convert([...utf8.encode('enc3-hmac'), ...nonce])
          .bytes,
    );
    return (encKey, macKey);
  }

  static Uint8List _computeMacTag(
    Uint8List macKey,
    Uint8List nonce,
    Uint8List cipherBytes,
  ) {
    final digest = Hmac(sha256, macKey).convert([...nonce, ...cipherBytes]).bytes;
    return Uint8List.fromList(digest.sublist(0, _macByteLength));
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _xorStream(
    Uint8List data,
    Uint8List key, {
    Uint8List? nonce,
  }) {
    final out = Uint8List(data.length);
    var block = 0;
    var i = 0;
    while (i < data.length) {
      final ks = sha256.convert([
        ...key,
        if (nonce != null) ...nonce,
        block & 0xff,
        (block >> 8) & 0xff,
      ]).bytes;
      for (var j = 0; j < ks.length && i < data.length; j++, i++) {
        out[i] = data[i] ^ ks[j];
      }
      block++;
    }
    return out;
  }

  /// يعمّي نصاً للتخزين بتشفير موثق (Encrypt-then-MAC `enc3:`) مع Nonce بحجم 16 بايت
  /// ووسم مصادقة HMAC-SHA256 بحجم 16 بايت لمنع التلاعب بالبيانات المشفرة:
  /// - افتراضياً (`deterministic: false`): يولّد Nonce عشوائياً آمناً (`Random.secure`).
  /// - عند طلب التعمية الحتمية (`deterministic: true` لأسرار الأقران `SecretStore`):
  ///   يشتق متجه التهيئة اصطناعياً (SIV) عبر `HMAC-SHA256(key, plain)`.
  static Future<String> protect(
    String plain, {
    bool deterministic = false,
  }) async {
    if (plain.isEmpty ||
        plain.startsWith(_prefixV3) ||
        plain.startsWith(_prefixV2) ||
        plain.startsWith(_prefixV1)) {
      return plain;
    }
    final key = await _key();
    final plainBytes = Uint8List.fromList(utf8.encode(plain));
    final Uint8List nonce;
    if (deterministic) {
      final mac = Hmac(sha256, key).convert(plainBytes).bytes;
      nonce = Uint8List.fromList(mac.sublist(0, _nonceLength));
    } else {
      final rnd = Random.secure();
      nonce = Uint8List.fromList(
        List<int>.generate(_nonceLength, (_) => rnd.nextInt(256)),
      );
    }
    final (encKey, macKey) = _deriveSubKeys(key, nonce);
    final enc = _xorStream(plainBytes, encKey, nonce: nonce);
    final macTag = _computeMacTag(macKey, nonce, enc);
    final combined = Uint8List(_nonceLength + _macByteLength + enc.length)
      ..setRange(0, _nonceLength, nonce)
      ..setRange(_nonceLength, _nonceLength + _macByteLength, macTag)
      ..setRange(
        _nonceLength + _macByteLength,
        _nonceLength + _macByteLength + enc.length,
        enc,
      );
    return '$_prefixV3${base64Encode(combined)}';
  }

  /// ينتج الصيغة التوافقية (`enc2:`) لأغراض مطابقة السجلات القديمة في `SecretStore.matchForms`.
  static Future<String> protectLegacyV2(
    String plain, {
    bool deterministic = true,
  }) async {
    if (plain.isEmpty ||
        plain.startsWith(_prefixV3) ||
        plain.startsWith(_prefixV2) ||
        plain.startsWith(_prefixV1)) {
      return plain;
    }
    final key = await _key();
    final plainBytes = Uint8List.fromList(utf8.encode(plain));
    final Uint8List nonce;
    if (deterministic) {
      final mac = Hmac(sha256, key).convert(plainBytes).bytes;
      nonce = Uint8List.fromList(mac.sublist(0, _nonceLength));
    } else {
      final rnd = Random.secure();
      nonce = Uint8List.fromList(
        List<int>.generate(_nonceLength, (_) => rnd.nextInt(256)),
      );
    }
    final enc = _xorStream(plainBytes, key, nonce: nonce);
    final combined = Uint8List(_nonceLength + enc.length)
      ..setRange(0, _nonceLength, nonce)
      ..setRange(_nonceLength, _nonceLength + enc.length, enc);
    return '$_prefixV2${base64Encode(combined)}';
  }

  /// ينتج الصيغة التوافقية القديمة (`enc1:`) لأغراض مطابقة السجلات القديمة في `SecretStore.matchForms`.
  static Future<String> protectLegacyV1(String plain) async {
    if (plain.isEmpty ||
        plain.startsWith(_prefixV3) ||
        plain.startsWith(_prefixV2) ||
        plain.startsWith(_prefixV1)) {
      return plain;
    }
    final key = await _key();
    final enc = _xorStream(Uint8List.fromList(utf8.encode(plain)), key);
    return '$_prefixV1${base64Encode(enc)}';
  }

  /// يفك التعمية (يدعم enc3 الموثق بـ HMAC، و enc2 المزود بـ Nonce، و enc1 القديم، والنص الصريح توافقاً خلفياً).
  static Future<String> reveal(String stored) async {
    if (stored.startsWith(_prefixV3)) {
      final key = await _key();
      try {
        final raw = Uint8List.fromList(
          base64Decode(stored.substring(_prefixV3.length)),
        );
        if (raw.length < _nonceLength + _macByteLength) return '';
        final nonce = Uint8List.sublistView(raw, 0, _nonceLength);
        final macTag = Uint8List.sublistView(
          raw,
          _nonceLength,
          _nonceLength + _macByteLength,
        );
        final cipher =
            Uint8List.sublistView(raw, _nonceLength + _macByteLength);
        final (encKey, macKey) = _deriveSubKeys(key, nonce);
        final expectedMac = _computeMacTag(macKey, nonce, cipher);
        if (!_constantTimeEquals(macTag, expectedMac)) return '';
        return utf8.decode(_xorStream(cipher, encKey, nonce: nonce));
      } catch (_) {
        return '';
      }
    }
    if (stored.startsWith(_prefixV2)) {
      final key = await _key();
      try {
        final raw = Uint8List.fromList(
          base64Decode(stored.substring(_prefixV2.length)),
        );
        if (raw.length < _nonceLength) return '';
        final nonce = Uint8List.sublistView(raw, 0, _nonceLength);
        final cipher = Uint8List.sublistView(raw, _nonceLength);
        return utf8.decode(_xorStream(cipher, key, nonce: nonce));
      } catch (_) {
        return '';
      }
    }
    if (!stored.startsWith(_prefixV1)) return stored;
    final key = await _key();
    try {
      final raw = base64Decode(stored.substring(_prefixV1.length));
      return utf8.decode(_xorStream(Uint8List.fromList(raw), key));
    } catch (_) {
      return '';
    }
  }
}
