// مسارات وسائط الدردشة والمرفقات — نسبية دائماً عند التخزين/المزامنة.
//
// المشكلة القديمة: المسار المطلق (/data/user/0/...) كان يُخزَّن في payload
// ويُرسَل عبر المزامنة، وهو بلا معنى على الجهاز المستقبل ويتعطل حتى محلياً
// إذا غيّر النظام مسار التطبيق بعد تحديث. الحل: نخزّن مساراً نسبياً من جذر
// documents (مثل chat_media/123_pic.jpg) ونحوّله لمطلق وقت الاستخدام فقط.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class MediaPaths {
  static String? _docsDir;

  /// الحد الأقصى لطول السلسلة النصية (Base64) للمصغّرة المتزامنة سحابياً (~26KB).
  static const int kMaxSyncedThumbBase64Chars = 36000;

  /// يهيئ جذر documents مرة واحدة (تُستدعى مبكراً؛ آمنة التكرار).
  static Future<String?> ensureDocsDir() async {
    if (_docsDir != null) return _docsDir;
    try {
      _docsDir = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      _docsDir = null; // بيئة اختبار VM بلا path_provider.
    }
    return _docsDir;
  }

  /// حقن الجذر في الاختبارات.
  static set docsDirForTesting(String? dir) => _docsDir = dir;

  /// يحوّل مساراً مطلقاً تحت documents إلى نسبي (للتخزين والمزامنة).
  /// مسار خارج documents أو جذر غير معروف يُعاد كما هو.
  static String toRelative(String absolute) {
    final root = _docsDir;
    if (root == null || root.isEmpty) return absolute;
    final norm = absolute.replaceAll('\\', '/');
    final rootNorm = root.replaceAll('\\', '/');
    if (norm.startsWith('$rootNorm/')) {
      return norm.substring(rootNorm.length + 1);
    }
    return absolute;
  }

  /// يحوّل مساراً مخزناً (نسبي جديد أو مطلق قديم) إلى مطلق للاستخدام.
  static String toAbsolute(String stored) {
    if (stored.isEmpty) return stored;
    // مطلق قديم (يبدأ بـ / أو حرف قرص ويندوز) — يُستخدم كما هو.
    if (stored.startsWith('/') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(stored)) {
      return stored;
    }
    final root = _docsDir;
    if (root == null || root.isEmpty) return stored;
    return '$root/$stored';
  }

  /// تجزئة SHA-256 (hex) لملف مخزَّن (نسبي أو مطلق). تُستخدم لجلب المرفقات
  /// عبر LAN بمعرّف محتوى ثابت بدل مسار الملف. تعيد '' عند أي فشل.
  static Future<String> fileHash(String stored) async {
    if (stored.isEmpty) return '';
    try {
      final f = File(toAbsolute(stored));
      if (!await f.exists()) return '';
      final digest = await sha256.bind(f.openRead()).first;
      return digest.toString();
    } catch (_) {
      return '';
    }
  }

  /// هل الملف المخزن (نسبي أو مطلق) موجود فعلاً؟
  static bool exists(String stored) {
    if (stored.isEmpty) return false;
    try {
      return File(toAbsolute(stored)).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// ضغط متوازن عالي الحدة للصورة (Crisp Thumbnail Resizing) ليناسب بطاقات الأصناف
  /// وشاشات Retina الحديثة (320px محلياً / 280px للمزامنة) بحجم خفيف (10–15KB).
  static Future<Uint8List> compressThumbnailBytes(
    Uint8List input, {
    int targetSize = 320,
    int maxBytes = 24576,
  }) async {
    if (input.isEmpty) return input;
    // إذا كانت الصورة مضغوطة مسبقاً بصيغة JPEG أو WebP من محرك النظام الأصلي (ImagePicker)
    // وتقع ضمن السقف المسموح، نحتفظ بها مباشرةً دون إعادة تشفيرها إلى PNG لتجنب فقدان الحدة.
    final isCompressedJpegOrWebp = (input.length >= 3 &&
            input[0] == 0xFF &&
            input[1] == 0xD8 &&
            input[2] == 0xFF) ||
        (input.length >= 12 &&
            input[0] == 0x52 &&
            input[1] == 0x49 &&
            input[2] == 0x46 &&
            input[3] == 0x46);
    if (isCompressedJpegOrWebp && input.length <= maxBytes) {
      return input;
    }
    try {
      final resized = await _resizeAndQuantizePng(
        input,
        maxDimension: targetSize,
        quantMask: 0xFC,
      );
      if (resized != null && resized.isNotEmpty) {
        // إذا كانت الصورة الأصلية مضغوطة مسبقاً (JPEG صغير) وأصغر من الـ PNG، نحتفظ بالأصغر
        if (input.length <= maxBytes && input.length <= resized.length) {
          return input;
        }
        if (resized.length <= maxBytes) {
          return resized;
        }
        // جولة ضغط ثانية متوازنة عند تجاوز السقف المسموح مع الحفاظ على وضوح التفاصيل
        final fallbackDim = (targetSize * 0.75).round().clamp(160, 280);
        final ultra = await _resizeAndQuantizePng(
          input,
          maxDimension: fallbackDim,
          quantMask: 0xF8,
        );
        if (ultra != null && ultra.isNotEmpty && ultra.length < resized.length) {
          return (input.length <= maxBytes && input.length < ultra.length)
              ? input
              : ultra;
        }
        return (input.length < resized.length) ? input : resized;
      }
    } catch (_) {
      // في بيئة الاختبار الصامتة أو عند تعذر فك الصورة عبر dart:ui
    }
    return input;
  }

  static Future<Uint8List?> _resizeAndQuantizePng(
    Uint8List input, {
    required int maxDimension,
    required int quantMask,
  }) async {
    final codec = await ui.instantiateImageCodec(
      input,
      targetWidth: maxDimension,
      targetHeight: maxDimension,
    );
    try {
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final w = img.width;
      final h = img.height;
      final rawData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (rawData == null) return null;
      final pixels = Uint8List.fromList(rawData.buffer.asUint8List());
      for (var i = 0; i + 3 < pixels.length; i += 4) {
        pixels[i] = pixels[i] & quantMask;
        pixels[i + 1] = pixels[i + 1] & quantMask;
        pixels[i + 2] = pixels[i + 2] & quantMask;
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        w,
        h,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final quantizedImg = await completer.future;
      final pngData =
          await quantizedImg.toByteData(format: ui.ImageByteFormat.png);
      quantizedImg.dispose();
      return pngData?.buffer.asUint8List();
    } finally {
      codec.dispose();
    }
  }

  /// يحفظ صورة صنف مختارة بعد ضغطها بدقة عالية (320px) كملف محلي ويعيد المسار النسبي.
  static Future<String> saveCompressedItemImage(String sourcePath) async {
    final dir = await ensureDocsDir();
    if (dir == null || dir.isEmpty) return '';
    final srcFile = File(sourcePath);
    if (!await srcFile.exists()) return '';
    final raw = await srcFile.readAsBytes();
    final compressed = await compressThumbnailBytes(raw, targetSize: 320);
    final hash = sha256.convert(compressed).toString().substring(0, 16);
    final subDir = Directory('$dir/item_thumbs');
    if (!subDir.existsSync()) {
      subDir.createSync(recursive: true);
    }
    final dest = '${subDir.path}/item_$hash.jpg';
    final outFile = File(dest);
    if (!outFile.existsSync() || outFile.lengthSync() != compressed.length) {
      await outFile.writeAsBytes(compressed, flush: true);
    }
    return toRelative(dest);
  }

  /// يحوّل صورة صنف محلية إلى نص Base64 مضغوط وواضح (280px) للمزامنة السحابية بين أجهزة المجموعة.
  static Future<String> encodeThumbBase64(String storedPath) async {
    if (storedPath.trim().isEmpty) return '';
    try {
      final f = File(toAbsolute(storedPath.trim()));
      if (!f.existsSync()) return '';
      final raw = await f.readAsBytes();
      if (raw.isEmpty) return '';
      final compressed = await compressThumbnailBytes(raw, targetSize: 280);
      final b64 = base64Encode(compressed);
      if (b64.length <= kMaxSyncedThumbBase64Chars) {
        return b64;
      }
      // في حال تجاوزت السقف نادراً، نضغط بجولة احتياطية تضمن بقاءها تحت 36000 محرف
      final tighter = await compressThumbnailBytes(
        raw,
        targetSize: 200,
        maxBytes: 18432,
      );
      final tighterB64 = base64Encode(tighter);
      if (tighterB64.length <= kMaxSyncedThumbBase64Chars) {
        return tighterB64;
      }
    } catch (_) {}
    return '';
  }

  /// يفك ترميز Base64 للمصغّرة المستلمة من السحابة ويحفظها كملف محلي ويعيد مسارها.
  static Future<String> materializeThumbBase64(
    String rawB64, {
    String prefix = 'item',
    bool returnAbsolute = false,
  }) async {
    var clean = rawB64.trim();
    if (clean.isEmpty) return '';
    final commaIdx = clean.indexOf(',');
    if (clean.startsWith('data:') && commaIdx != -1) {
      clean = clean.substring(commaIdx + 1).trim();
    }
    try {
      final bytes = base64Decode(clean);
      if (bytes.isEmpty) return '';
      final hash = sha256.convert(bytes).toString().substring(0, 16);
      final docs = await ensureDocsDir();
      final baseDir = (docs != null && docs.isNotEmpty)
          ? '$docs/item_thumbs'
          : '${Directory.systemTemp.path}/almohaseb_thumbs';
      final dir = Directory(baseDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final file = File('${dir.path}/${prefix}_$hash.jpg');
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        await file.writeAsBytes(bytes, flush: true);
      }
      if (returnAbsolute || docs == null || docs.isEmpty) {
        return file.path;
      }
      return toRelative(file.path);
    } catch (_) {
      return '';
    }
  }
}

