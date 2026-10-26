// التحديث بنقرة واحدة (أندرويد):
// ينزّل ملف الـ APK عبر DownloadManager (خدمة نظام) ثم يفتح شاشة تثبيت
// النظام مباشرةً — يبقى القرار النهائي للمستخدم في حوار النظام (لا يسمح
// أندرويد بتثبيت صامت لتطبيقات خارج المتجر، وهذا قيد أمني في النظام نفسه).
//
// لماذا DownloadManager بدل http داخل التطبيق؟
// 1) السرعة: تنزيل داخل عملية التطبيق يخضع لكبح النظام للتطبيقات الخاملة
//    ولقيود Dart isolate، بينما مدير التنزيلات خدمة نظام مخصصة لذلك.
// 2) الاستمرارية: يواصل التنزيل حتى لو أُغلق التطبيق نهائياً.
// 3) الاستئناف: يستأنف تلقائياً بعد انقطاع الشبكة (HTTP Range)، وعند فتح
//    التطبيق مجدداً نلتقط التنزيل الجاري/المكتمل بدل البدء من الصفر.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/sfx.dart';
import '../core/platform_info.dart';

/// مراحل عملية التحديث بنقرة واحدة.
enum InstallPhase {
  idle,
  downloading,
  launchingInstaller,
  awaitingPermission,
  failed,
  done,
}

/// حالة لحظية تُبث أثناء التنزيل/التثبيت لعرض شريط التقدم.
class InstallProgress {
  final InstallPhase phase;

  /// نسبة التنزيل 0..1 (أو null إذا كان الحجم مجهولاً).
  final double? progress;
  final String? error;

  const InstallProgress(this.phase, {this.progress, this.error});
}

class UpdateInstaller {
  static const _channel = MethodChannel('nexora/updates');

  final http.Client Function() _clientFactory;

  UpdateInstaller({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? (() => http.Client());

  /// يحسب بصمة التجزئة SHA-256 للملف المنزّل.
  static Future<String> computeFileSha256(File file) async {
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase();
  }

  /// يتحقق من تطابق بصمة التجزئة SHA-256 للملف المنزّل مع البصمة المرفقة في بيان التحديث.
  static Future<bool> verifyFileSha256(
    File file,
    String? expectedSha256,
  ) async {
    final expected = expectedSha256?.trim().toLowerCase() ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      return false;
    }
    try {
      if (!file.existsSync()) return false;
      final actual = await computeFileSha256(file);
      return actual == expected;
    } catch (_) {
      return false;
    }
  }

  /// يتحقق من إمكانية قراءة ملف الـ APK المنزّل فعلياً على أندرويد 11+ (Scoped Storage).
  static Future<bool> _canReadFile(File file) async {
    try {
      if (!file.existsSync() || file.lengthSync() <= 1024 * 1024) return false;
      await file.openRead(0, 16).first;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// هل منح المستخدم إذن «تثبيت التطبيقات غير المعروفة» لهذا التطبيق؟
  Future<bool> canInstall() async {
    // ويندوز لا يحتاج إذناً مسبقاً: تشغيل المُثبّت يُظهر حوار UAC للنظام.
    if (PlatformInfo.isWindows) return true;
    if (!PlatformInfo.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// يفتح صفحة إعدادات النظام لمنح إذن التثبيت (مرة واحدة فقط).
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  // ------- تذكّر معرّف التنزيل والرابط بين تشغيلات التطبيق (للاستئناف الدقيق) -------

  Future<File> _idFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/update_download_state.json');
  }

  Future<File> _legacyIdFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/update_download_id.txt');
  }

  Future<({int id, String url})?> _savedDownload() async {
    try {
      // إتلاف الملف القديم لتفادي تثبيت أي حزم سابقة قديمة
      final leg = await _legacyIdFile();
      if (leg.existsSync()) await leg.delete();

      final f = await _idFile();
      if (!f.existsSync()) return null;
      final raw = await f.readAsString();
      final map = jsonDecode(raw);
      if (map is Map) {
        final id = (map['id'] is int) ? map['id'] as int : int.tryParse('${map['id']}');
        final u = map['url']?.toString();
        if (id != null && u != null && u.isNotEmpty) {
          return (id: id, url: u);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDownload(int? id, String? url) async {
    try {
      final f = await _idFile();
      if (id == null || url == null) {
        if (f.existsSync()) await f.delete();
      } else {
        await f.writeAsString(jsonEncode({'id': id, 'url': url}));
      }
    } catch (_) {}
  }

  Future<Map<String, Object?>> _query(int id) async {
    try {
      final r = await _channel
          .invokeMapMethod<String, Object?>('queryDownload', {'id': id});
      return r ?? const {'status': 'unknown'};
    } catch (_) {
      return const {'status': 'unknown'};
    }
  }

  Future<void> _cancelDownload(int id) async {
    try {
      await _channel.invokeMethod('cancelDownload', {'id': id});
    } catch (_) {}
  }

  /// ينزّل APK/EXE من [url] ويبث التقدم، ثم يتحقق من بصمة SHA-256 ويفتح شاشة تثبيت النظام.
  /// لا يرمي استثناءً — يبث InstallPhase.failed مع سبب عربي مفهوم.
  Stream<InstallProgress> downloadAndInstall(
    String url, {
    String? expectedSha256,
    String? sha256,
    String? fallbackUrl,
  }) async* {
    final targetSha256 = (expectedSha256 ?? sha256)?.trim();
    if (targetSha256 == null ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(targetSha256)) {
      yield const InstallProgress(
        InstallPhase.failed,
        error: 'تعذّر بدء التحديث: بصمة التحقق الرقمية (sha256) مفقودة أو غير صالحة في البيان.',
      );
      return;
    }
    if (PlatformInfo.isWindows) {
      yield* _windowsDownloadAndInstall(
        url,
        expectedSha256: targetSha256,
        fallbackUrl: fallbackUrl,
      );
      return;
    }
    if (!PlatformInfo.isAndroid) {
      yield const InstallProgress(InstallPhase.failed,
          error: 'التحديث المباشر متاح على أندرويد وويندوز فقط.');
      return;
    }

    // 0) إذن «المصادر غير المعروفة»: إن لم يُمنح نفتح إعداداته وننتظر المستخدم.
    if (!await canInstall()) {
      yield const InstallProgress(InstallPhase.awaitingPermission);
      await openInstallSettings();
      // ننتظر عودة المستخدم من الإعدادات (فحص دوري بمهلة قصوى دقيقة واحدة).
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (await canInstall()) break;
      }
      if (!await canInstall()) {
        yield const InstallProgress(InstallPhase.failed,
            error: 'لم يُمنح إذن تثبيت التحديثات. فعّله من إعدادات النظام '
                'ثم أعد المحاولة.');
        return;
      }
    }

    yield const InstallProgress(InstallPhase.downloading, progress: 0);

    // 1) استئناف تنزيل سابق إن وُجد وكان لنفس الرابط المطلوب حصراً ويتحرك فعلياً
    var saved = await _savedDownload();
    int? id;
    if (saved != null && saved.url == url) {
      final st = await _query(saved.id);
      final status = '${st['status']}';
      final bytes = (st['bytes'] as num?)?.toInt() ?? 0;
      if (status == 'done' && '${st['path']}'.isNotEmpty) {
        final apk = File('${st['path']}');
        if (await _canReadFile(apk)) {
          // اكتمل في الخلفية لنفس هذا الرابط — أشعر ثم ثبّت مباشرة بعد فحص البصمة
          _notifyDownloadComplete('${st['path']}');
          yield* _install('${st['path']}', expectedSha256: targetSha256);
          return;
        }
      }
      // لا نستأنف تنزيلاً عالقاً على صفر بايت أو paused/pending عند طلب المستخدم الصريح
      if (status == 'running' && bytes > 0) {
        id = saved.id;
      } else {
        await _cancelDownload(saved.id);
      }
    } else if (saved != null) {
      await _cancelDownload(saved.id);
    }

    // تنظيف أي حالة تنزيل قديمة مخالفة للرابط الحالي
    if (id == null) {
      await _saveDownload(null, null);
    }

    // 2) بدء تنزيل جديد عبر مدير تنزيلات النظام.
    if (id == null) {
      try {
        final r = await _channel.invokeMethod<Object?>(
            'startDownload', {'url': url});
        final started = (r is int) ? r : int.tryParse('$r') ?? -1;
        if (started >= 0) {
          id = started;
          await _saveDownload(id, url);
        }
      } catch (_) {}
    }

    if (id == null) {
      // مسار احتياطي (أجهزة عطّل فيها مدير التنزيلات): تنزيل مباشر.
      yield* _fallbackHttpDownload(
        url,
        expectedSha256: targetSha256,
        fallbackUrl: fallbackUrl,
      );
      return;
    }

    // 3) متابعة التقدم — وإن علق DownloadManager أو كان بطيئاً جداً ننتقل للتنزيل المتوازي السريع.
    var stuckCount = 0;
    var zeroByteTicks = 0;
    var stalledTicks = 0;
    var totalTicks = 0;
    var lastBytes = -1;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      totalTicks++;
      final st = await _query(id);
      final status = '${st['status']}';
      final bytes = (st['bytes'] as num?)?.toInt() ?? 0;
      final total = (st['total'] as num?)?.toInt() ?? -1;
      if (bytes <= 0) {
        zeroByteTicks++;
      } else {
        zeroByteTicks = 0;
        if (bytes == lastBytes) {
          stalledTicks++;
        } else {
          stalledTicks = 0;
          lastBytes = bytes;
        }
      }
      // إذا كان التنزيل أبطأ من 20KB/s بعد 6 ثوانٍ (أقل من 120KB) ننتقل للمنزّل المتوازي السريع
      final tooSlow = totalTicks >= 12 && bytes < 120 * 1024;
      switch (status) {
        case 'done':
          final path = '${st['path']}';
          await _saveDownload(null, null);
          if (path.isEmpty || !await _canReadFile(File(path))) {
            yield* _fallbackHttpDownload(
              url,
              expectedSha256: targetSha256,
              fallbackUrl: fallbackUrl,
            );
            return;
          }
          // (2026-09-22) إشعار نظام: اكتمل التنزيل — نقرة تفتح المجلد.
          _notifyDownloadComplete(path);
          yield* _install(path, expectedSha256: targetSha256);
          return;
        case 'failed':
          await _cancelDownload(id);
          await _saveDownload(null, null);
          yield* _fallbackHttpDownload(
            url,
            expectedSha256: targetSha256,
            fallbackUrl: fallbackUrl,
          );
          return;
        case 'paused':
          if (zeroByteTicks >= 10 || stalledTicks >= 16 || tooSlow) {
            await _cancelDownload(id);
            await _saveDownload(null, null);
            yield* _fallbackHttpDownload(
              url,
              expectedSha256: targetSha256,
              fallbackUrl: fallbackUrl,
            );
            return;
          }
          yield InstallProgress(InstallPhase.downloading,
              progress: (total > 0) ? bytes / total : 0.0);
          break;
        case 'unknown':
          if (++stuckCount >= 6) {
            await _cancelDownload(id);
            await _saveDownload(null, null);
            yield* _fallbackHttpDownload(
              url,
              expectedSha256: targetSha256,
              fallbackUrl: fallbackUrl,
            );
            return;
          }
          break;
        default: // running / pending
          stuckCount = 0;
          if (zeroByteTicks >= 10 || stalledTicks >= 16 || tooSlow) {
            await _cancelDownload(id);
            await _saveDownload(null, null);
            yield* _fallbackHttpDownload(
              url,
              expectedSha256: targetSha256,
              fallbackUrl: fallbackUrl,
            );
            return;
          }
          yield InstallProgress(InstallPhase.downloading,
              progress: (total > 0) ? bytes / total : 0.0);
      }
    }
  }

  /// (2026-09-22) إشعار نظام بعد اكتمال تنزيل التحديث — نقرته تفتح
  /// مجلد التنزيلات العام (Download/Nexora) عبر openNotificationEntity.
  void _notifyDownloadComplete(String path) {
    Sfx.systemNotify(
      title: 'اكتمل تنزيل التحديث',
      body: 'الملف محفوظ في Download/Nexora — اضغط لفتح مجلد التنزيلات.',
      entityType: 'update_download',
      entityId: path,
    );
  }

  /// يفتح مجلد التنزيلات العام الذي يحفظ فيه التطبيق ملفات التحديث —
  /// أندرويد: نافذة مستندات النظام؛ ويندوز: المستكشف على الملف نفسه.
  static Future<bool> openDownloadsFolder(String path) async {
    try {
      if (PlatformInfo.isAndroid) {
        final r = await _channel.invokeMethod<bool>('openDownloadsFolder');
        return r ?? false;
      }
      if (PlatformInfo.isWindows && path.isNotEmpty) {
        await Process.start('explorer.exe', ['/select,', path],
            mode: ProcessStartMode.detached);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// يتحقق من الملف وبصمة SHA-256 ثم يطلق شاشة تثبيت النظام.
  Stream<InstallProgress> _install(
    String path, {
    required String expectedSha256,
  }) async* {
    final apk = File(path);
    if (!apk.existsSync() || apk.lengthSync() < 1024 * 1024) {
      await _saveDownload(null, null);
      yield const InstallProgress(InstallPhase.failed,
          error: 'الملف المنزَّل غير مكتمل. أعد المحاولة.');
      return;
    }
    final validHash = await verifyFileSha256(apk, expectedSha256);
    if (!validHash) {
      try {
        await apk.delete();
      } catch (_) {}
      await _saveDownload(null, null);
      yield const InstallProgress(
        InstallPhase.failed,
        error: 'فشل التحقق من بصمة التجزئة (sha256) لملف التحديث. تم حظر التثبيت لحمايتك.',
      );
      return;
    }
    yield const InstallProgress(InstallPhase.launchingInstaller, progress: 1);
    try {
      final r =
          await _channel.invokeMethod<String>('installApk', {'path': path});
      await _saveDownload(null, null);
      if (r == 'ok') {
        yield const InstallProgress(InstallPhase.done, progress: 1);
      } else {
        yield InstallProgress(InstallPhase.failed,
            error: switch (r) {
              'file_missing' => 'ملف التحديث اختفى بعد التنزيل.',
              'uri_failed' => 'تعذّر تجهيز ملف التثبيت.',
              _ => 'تعذّر فتح شاشة التثبيت.',
            });
      }
    } catch (e) {
      await _saveDownload(null, null);
      yield InstallProgress(InstallPhase.failed,
          error: 'تعذّر فتح شاشة التثبيت: $e');
    }
  }

  // ------------------------- مسار ويندوز -------------------------

  /// ويندوز: ينزّل مُثبّت NexoraSetup.exe (أو الملف المتاح) داخل التطبيق
  /// ثم يتحقق من بصمة SHA-256 ويشغّله — معالج التثبيت يحدّث النسخة فوق الحالية مع بقاء البيانات.
  Stream<InstallProgress> _windowsDownloadAndInstall(
    String url, {
    required String expectedSha256,
    String? fallbackUrl,
  }) async* {
    yield const InstallProgress(InstallPhase.downloading, progress: 0);
    final segs = Uri.tryParse(url)?.pathSegments ?? const <String>[];
    final name = segs.isEmpty ? '' : segs.last;
    final isExe = name.toLowerCase().endsWith('.exe');
    final fileName = isExe ? 'NexoraSetup.exe' : 'nexora-update.zip';
    yield* _httpDownload(
      url,
      fileName,
      (file) async* {
        if (file.lengthSync() < 512 * 1024) {
          yield const InstallProgress(InstallPhase.failed,
              error: 'الملف المنزَّل غير مكتمل. أعد المحاولة.');
          return;
        }
        final validHash = await verifyFileSha256(file, expectedSha256);
        if (!validHash) {
          try {
            await file.delete();
          } catch (_) {}
          yield const InstallProgress(
            InstallPhase.failed,
            error: 'فشل التحقق من بصمة التجزئة (sha256) لملف التحديث. تم حظر التثبيت لحمايتك.',
          );
          return;
        }
        yield const InstallProgress(InstallPhase.launchingInstaller,
            progress: 1);
        try {
          if (isExe) {
            try {
              await Process.start(
                'powershell.exe',
                [
                  '-NoProfile',
                  '-NonInteractive',
                  '-Command',
                  'Start-Process -FilePath \'${file.path}\' -Verb RunAs',
                ],
                mode: ProcessStartMode.detached,
                runInShell: false,
              );
            } catch (_) {
              await Process.start(
                'cmd.exe',
                ['/c', 'start', '', file.path],
                mode: ProcessStartMode.detached,
                runInShell: false,
              );
            }
          } else {
            await Process.start('explorer.exe', ['/select,', file.path],
                mode: ProcessStartMode.detached);
          }
          yield const InstallProgress(InstallPhase.done, progress: 1);
        } catch (e) {
          yield InstallProgress(InstallPhase.failed,
              error: 'تعذّر تشغيل المُثبّت: $e');
        }
      },
      fallbackUrl: fallbackUrl,
    );
  }

  /// مسار احتياطي: تنزيل http داخل التطبيق إذا تعذّر أو علق مدير تنزيلات النظام.
  Stream<InstallProgress> _fallbackHttpDownload(
    String url, {
    required String expectedSha256,
    String? fallbackUrl,
  }) async* {
    yield* _httpDownload(
      url,
      'nexora-update.apk',
      (f) => _install(f.path, expectedSha256: expectedSha256),
      fallbackUrl: fallbackUrl,
    );
  }

  /// مجلد التنزيل: على أندرويد نستخدم مجلد الكاش الداخلي أو الخارجي الخاص بالتطبيق
  /// لضمان صلاحية القراءة والكتابة الكاملة على أندرويد 11+ (Scoped Storage) دون خطأ errno=13.
  Future<Directory> _downloadDir(String fileName) async {
    Directory? dir;
    if (PlatformInfo.isAndroid) {
      try {
        final cacheDirPath =
            await _channel.invokeMethod<String>('cacheUpdateDir');
        if (cacheDirPath != null && cacheDirPath.isNotEmpty) {
          final d = Directory(cacheDirPath);
          await d.create(recursive: true);
          dir = d;
        }
      } catch (_) {}
      if (dir == null) {
        try {
          final ext = await getExternalStorageDirectory();
          if (ext != null) {
            final d = Directory('${ext.path}/updates');
            await d.create(recursive: true);
            dir = d;
          }
        } catch (_) {}
      }
    }
    if (dir == null) {
      final cache = await getTemporaryDirectory();
      final d = Directory('${cache.path}/updates');
      if (d.existsSync()) d.deleteSync(recursive: true);
      d.createSync(recursive: true);
      dir = d;
    }
    // نظّف ملفات التحديث القديمة حتى لا تتراكم وتهدر مساحة الهاتف.
    try {
      await for (final e in dir.list()) {
        if (e is File) {
          await e.delete();
        }
      }
    } catch (_) {}
    return dir;
  }

  /// يرتب روابط التنزيل بحيث تُقدَّم مرايا Fastly السريعة (GitHub Pages / raw)
  /// على روابط Azure البطيئة في اليمن، مع دعم التنزيل المتوازي متعدد الاتصالات.
  List<String> _buildFastCandidateUrls(String primary, String? fallback) {
    final rawSet = <String>{
      if (primary.trim().isNotEmpty) primary.trim(),
      if (fallback != null && fallback.trim().isNotEmpty) fallback.trim(),
    };
    final fastMirrors = <String>[];
    final others = <String>[];
    for (final u in rawSet) {
      if (u.contains('github.io/almohaseb-v2/releases/')) {
        fastMirrors.add(u);
        final idx = u.indexOf('/releases/');
        if (idx >= 0) {
          final tail = u.substring(idx + 1).split('?').first;
          fastMirrors.add(
            'https://raw.githubusercontent.com/iggdigd218-dev/almohaseb-v2/releases/$tail',
          );
        }
      } else {
        others.add(u);
      }
    }
    return <String>{...fastMirrors, ...others}.toList();
  }

  /// تنزيل متوازٍ عبر 6 اتصالات HTTP Range متزامنة لتسريع التنزيل 6 أضعاف على الشبكات المقيّدة.
  Future<bool> _downloadParallelRanges(
    String candidateUrl,
    File targetFile,
    int totalBytes,
    void Function(double progress) onProgress,
  ) async {
    const chunkCount = 6;
    final dir = targetFile.parent;
    final partFiles = List<File>.generate(
      chunkCount,
      (i) => File('${dir.path}/part_$i.tmp'),
    );
    final receivedPerChunk = List<int>.filled(chunkCount, 0);
    final chunkSize = (totalBytes / chunkCount).ceil();
    var lastReport = DateTime.now();

    Future<bool> downloadPart(int index) async {
      final start = index * chunkSize;
      if (start >= totalBytes) return true;
      final end = ((index + 1) * chunkSize - 1).clamp(start, totalBytes - 1);
      final expectedLen = end - start + 1;
      for (var retry = 0; retry < 2; retry++) {
        final client = _clientFactory();
        IOSink? sink;
        try {
          receivedPerChunk[index] = 0;
          final req = http.Request('GET', Uri.parse(candidateUrl));
          req.headers['Range'] = 'bytes=$start-$end';
          final res =
              await client.send(req).timeout(const Duration(seconds: 20));
          if (res.statusCode != 206) {
            return false;
          }
          sink = partFiles[index].openWrite();
          var partGot = 0;
          await for (final chunk
              in res.stream.timeout(const Duration(seconds: 30))) {
            sink.add(chunk);
            partGot += chunk.length;
            receivedPerChunk[index] = partGot;
            final now = DateTime.now();
            if (now.difference(lastReport).inMilliseconds > 120) {
              lastReport = now;
              final sum = receivedPerChunk.fold<int>(0, (a, b) => a + b);
              onProgress((sum / totalBytes).clamp(0.0, 0.99));
            }
          }
          await sink.flush();
          await sink.close();
          sink = null;
          if (partGot == expectedLen) return true;
        } catch (_) {
          // retry
        } finally {
          try {
            await sink?.close();
          } catch (_) {}
          client.close();
        }
      }
      return false;
    }

    try {
      final results =
          await Future.wait(List.generate(chunkCount, downloadPart));
      if (results.any((ok) => !ok)) return false;
      final outSink = targetFile.openWrite();
      try {
        for (final pf in partFiles) {
          if (pf.existsSync()) {
            await outSink.addStream(pf.openRead());
          }
        }
        await outSink.flush();
      } finally {
        await outSink.close();
      }
      onProgress(1.0);
      return targetFile.existsSync() && targetFile.lengthSync() == totalBytes;
    } catch (_) {
      return false;
    } finally {
      for (final pf in partFiles) {
        try {
          if (pf.existsSync()) await pf.delete();
        } catch (_) {}
      }
    }
  }

  /// تنزيل http عام إلى ملف مؤقت (مع التنزيل المتوازي والتبديل التلقائي للرابط الاحتياطي).
  Stream<InstallProgress> _httpDownload(
    String url,
    String fileName,
    Stream<InstallProgress> Function(File file) onDone, {
    String? fallbackUrl,
  }) async* {
    final urlsToTry = _buildFastCandidateUrls(url, fallbackUrl);

    String? lastError;
    for (var attempt = 0; attempt < urlsToTry.length; attempt++) {
      final candidateUrl = urlsToTry[attempt];
      File? apk;
      try {
        final dir = await _downloadDir(fileName);
        apk = File('${dir.path}/$fileName');
      } catch (e) {
        lastError = 'تعذّر تجهيز مجلد التنزيل: $e';
        break;
      }

      yield const InstallProgress(InstallPhase.downloading, progress: 0.0);

      // 1) محاولة التنزيل المتوازي السريع (6 اتصالات Range) إذا كان الخادم يدعمه
      var downloadedOk = false;
      try {
        final probeClient = _clientFactory();
        try {
          final headReq = http.Request('HEAD', Uri.parse(candidateUrl));
          final headRes = await probeClient
              .send(headReq)
              .timeout(const Duration(seconds: 12));
          final totalLen = headRes.contentLength ?? -1;
          final acceptsRanges =
              (headRes.headers['accept-ranges'] ?? '').toLowerCase() == 'bytes';
          if (headRes.statusCode >= 200 &&
              headRes.statusCode < 300 &&
              acceptsRanges &&
              totalLen > 2 * 1024 * 1024) {
            final progressController = StreamController<InstallProgress>();
            final future = _downloadParallelRanges(
              candidateUrl,
              apk,
              totalLen,
              (p) {
                if (!progressController.isClosed) {
                  progressController
                      .add(InstallProgress(InstallPhase.downloading, progress: p));
                }
              },
            ).whenComplete(() => progressController.close());
            await for (final ev in progressController.stream) {
              yield ev;
            }
            downloadedOk = await future;
          }
        } finally {
          probeClient.close();
        }
      } catch (_) {}

      // 2) المسار المتسلسل القياسي إذا لم يدعم الخادم Range
      if (!downloadedOk) {
        final client = _clientFactory();
        IOSink? sink;
        try {
          final req = http.Request('GET', Uri.parse(candidateUrl));
          final res =
              await client.send(req).timeout(const Duration(seconds: 25));
          if (res.statusCode < 200 || res.statusCode >= 300) {
            lastError = 'الخادم أعاد الرمز ${res.statusCode}.';
          } else {
            final total = res.contentLength;
            var received = 0;
            sink = apk.openWrite();
            var lastYield = DateTime.now();
            await for (final chunk
                in res.stream.timeout(const Duration(seconds: 45))) {
              sink.add(chunk);
              received += chunk.length;
              final now = DateTime.now();
              if (now.difference(lastYield).inMilliseconds > 120) {
                lastYield = now;
                yield InstallProgress(
                  InstallPhase.downloading,
                  progress: (total != null && total > 0)
                      ? (received / total).clamp(0.0, 1.0)
                      : (received / (22 * 1024 * 1024)).clamp(0.01, 0.95),
                );
              }
            }
            await sink.flush();
            await sink.close();
            sink = null;
            downloadedOk = true;
          }
        } on TimeoutException {
          lastError = 'انقطع الاتصال أثناء التنزيل. أعد المحاولة.';
        } catch (e) {
          lastError = 'فشل التنزيل: $e';
        } finally {
          try {
            await sink?.close();
          } catch (_) {}
          client.close();
        }
      }

      if (downloadedOk && apk.existsSync() && apk.lengthSync() > 0) {
        yield* onDone(apk);
        return;
      }
    }

    yield InstallProgress(
      InstallPhase.failed,
      error: lastError ?? 'تعذّر تنزيل التحديث. تحقق من الاتصال ثم أعد المحاولة.',
    );
  }
}
