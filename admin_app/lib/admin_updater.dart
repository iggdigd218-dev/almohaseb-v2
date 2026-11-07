// نظام التحديث المستقل والموحّد لتطبيق مدير التراخيص (License Admin App).
//
// المزايا المعمارية:
// 1) مصدر تحديث مركزي موحّد لكلا المستودعين (المحاسب v2 + المحاسب بلاس) عبر
//    عقدة `/system/admin_version_manifest.json` ومرآة Fastly السريعة (`github.io/almohaseb-v2`).
// 2) تحديث فوري داخل التطبيق بنقرة واحدة (In-App One-Click Update) دون التحويل
//    الإجباري للمتصفح، مع انتقال تلقائي ذكي من DownloadManager إلى محرك HTTP
//    المباشر داخل التطبيق إذا تأخر بدء التنزيل، ودعم الرابط الاحتياطي (`fallbackDownloadUrl`).
// 3) التحقق من سلامة الحزمة المنزّلة وبصمة SHA-256 قبل إطلاق مثبّت حزم أندرويد.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io'
    show Directory, File, HttpClient, HttpHeaders, IOSink, Platform, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// إصدار تطبيق مدير التراخيص الحالي (يطابق admin_app/pubspec.yaml).
const String kAdminAppVersion = '1.8.7';

/// رقم بناء تطبيق مدير التراخيص (ما بعد + في admin_app/pubspec.yaml).
const int kAdminAppBuild = 57;

String get adminFullVersion => '$kAdminAppVersion+$kAdminAppBuild';

class AdminSemVer implements Comparable<AdminSemVer> {
  final int major;
  final int minor;
  final int patch;
  final int build;

  const AdminSemVer(this.major, this.minor, this.patch, [this.build = 0]);

  static const AdminSemVer current = AdminSemVer(1, 8, 7, kAdminAppBuild);

  static AdminSemVer? tryParse(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?(?:\+(\d+))?').firstMatch(raw);
    if (m == null) return null;
    return AdminSemVer(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.tryParse(m.group(3) ?? '0') ?? 0,
      int.tryParse(m.group(4) ?? '0') ?? 0,
    );
  }

  @override
  int compareTo(AdminSemVer o) {
    if (major != o.major) return major.compareTo(o.major);
    if (minor != o.minor) return minor.compareTo(o.minor);
    if (patch != o.patch) return patch.compareTo(o.patch);
    return build.compareTo(o.build);
  }

  bool operator >(AdminSemVer o) => compareTo(o) > 0;
  bool operator <(AdminSemVer o) => compareTo(o) < 0;

  @override
  String toString() =>
      build > 0 ? '$major.$minor.$patch+$build' : '$major.$minor.$patch';
}

String? _androidAbiKey() {
  try {
    if (!Platform.isAndroid) return null;
    switch (ffi.Abi.current()) {
      case ffi.Abi.androidArm64:
        return 'arm64';
      case ffi.Abi.androidArm:
        return 'armv7';
      case ffi.Abi.androidX64:
        return 'x64';
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

String? _pickAdminApkUrl(Object? downloads, String? abiKey) {
  if (downloads is! Map) return null;
  if (abiKey != null) {
    final variants = downloads['androidVariants'];
    if (variants is Map) {
      final v = variants[abiKey];
      if (v is String && v.startsWith('https://')) return v;
    }
  }
  final v = downloads['android'];
  return (v is String && v.startsWith('https://')) ? v : null;
}

String? _pickAdminSha256(Map<String, Object?> map, String? abiKey) {
  final variants = map['sha256Variants'];
  if (variants is Map && abiKey != null) {
    final v = variants[abiKey]?.toString().trim();
    if (v != null && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(v)) {
      return v.toLowerCase();
    }
  }
  final raw = map['sha256']?.toString().trim();
  if (raw != null && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(raw)) {
    return raw.toLowerCase();
  }
  return null;
}

enum AdminUpdateStatus { upToDate, available, unknown }

class AdminUpdateInfo {
  final AdminUpdateStatus status;
  final AdminSemVer current;
  final AdminSemVer? latest;
  final String? downloadUrl;
  final String? fallbackDownloadUrl;
  final String? sha256;
  final String? releaseUrl;
  final String notes;
  final String? error;

  const AdminUpdateInfo({
    required this.status,
    required this.current,
    this.latest,
    this.downloadUrl,
    this.fallbackDownloadUrl,
    this.sha256,
    this.releaseUrl,
    this.notes = '',
    this.error,
  });

  bool get hasUpdate => status == AdminUpdateStatus.available;

  String get headline => switch (status) {
        AdminUpdateStatus.upToDate => 'تطبيق التراخيص محدَّث',
        AdminUpdateStatus.available => 'يتوفّر تحديث جديد لتطبيق التراخيص',
        AdminUpdateStatus.unknown => 'تعذّر التحقق من التحديثات',
      };
}

class AdminUpdateService {
  static const String kDefaultManifestUrl =
      'https://nexora-broker-default-rtdb.europe-west1.firebasedatabase.app/system/admin_version_manifest.json';

  static const String kLegacyManifestUrl =
      'https://nexora-broker-default-rtdb.europe-west1.firebasedatabase.app/workspaces/_registry/system/admin_version_manifest.json';

  static const String kMirrorManifestUrl =
      'https://iggdigd218-dev.github.io/almohaseb-v2/admin_version.json';

  static const String kFallbackManifestUrl =
      'https://github.com/iggdigd218-dev/almohaseb-v2/releases/download/admin-latest/admin_version.json';

  static const String kFallbackReleaseUrl =
      'https://github.com/iggdigd218-dev/almohaseb-v2/releases/tag/admin-latest';

  static const String kMirrorApkUrl =
      'https://iggdigd218-dev.github.io/almohaseb-v2/license-admin.apk';

  static const String kDefaultApkUrl =
      'https://github.com/iggdigd218-dev/almohaseb-v2/releases/download/admin-latest/license-admin.apk';

  final String manifestUrl;
  final AdminSemVer current;

  AdminUpdateService({
    this.manifestUrl = kDefaultManifestUrl,
    this.current = AdminSemVer.current,
  });

  Future<AdminUpdateInfo> check() async {
    var best = await _fetchFromUrl(manifestUrl);
    if (manifestUrl == kDefaultManifestUrl) {
      for (final url in const [
        kLegacyManifestUrl,
        kMirrorManifestUrl,
        kFallbackManifestUrl,
      ]) {
        if (best.hasUpdate && url == kFallbackManifestUrl) break;
        final candidate = await _fetchFromUrl(url);
        if (candidate.status == AdminUpdateStatus.unknown) continue;
        if (best.status == AdminUpdateStatus.unknown) {
          best = candidate;
        } else if (candidate.latest != null &&
            (best.latest == null || candidate.latest! > best.latest!)) {
          best = candidate;
        }
      }
    }
    return best;
  }

  Future<AdminUpdateInfo> _fetchFromUrl(String targetUrl) async {
    final uri = Uri.tryParse(targetUrl);
    if (uri == null || !uri.isScheme('https')) {
      return AdminUpdateInfo(
        status: AdminUpdateStatus.unknown,
        current: current,
        error: 'رابط بيان التحديث غير صالح.',
      );
    }
    final uriWithBuster = uri.replace(queryParameters: {
      ...uri.queryParameters,
      't': '${DateTime.now().millisecondsSinceEpoch}',
    });
    final client = http.Client();
    try {
      final res = await client.get(uriWithBuster, headers: {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return AdminUpdateInfo(
          status: AdminUpdateStatus.unknown,
          current: current,
          error: 'الخادم أعاد الرمز ${res.statusCode}.',
        );
      }
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      if (body.trim() == 'null' || body.trim().isEmpty) {
        return AdminUpdateInfo(
          status: AdminUpdateStatus.unknown,
          current: current,
          error: 'لم يُنشر بيان تحديث بعد.',
        );
      }
      return _parse(body);
    } on SocketException {
      return AdminUpdateInfo(
        status: AdminUpdateStatus.unknown,
        current: current,
        error: 'تعذّر الاتصال بالإنترنت.',
      );
    } on TimeoutException {
      return AdminUpdateInfo(
        status: AdminUpdateStatus.unknown,
        current: current,
        error: 'انتهت مهلة الاتصال.',
      );
    } catch (e) {
      return AdminUpdateInfo(
        status: AdminUpdateStatus.unknown,
        current: current,
        error: 'تعذّر فحص التحديثات: $e',
      );
    } finally {
      client.close();
    }
  }

  AdminUpdateInfo _parse(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return AdminUpdateInfo(
        status: AdminUpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث تالف.',
      );
    }
    if (decoded is! Map) {
      return AdminUpdateInfo(
        status: AdminUpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث بصيغة غير متوقعة.',
      );
    }
    final map = Map<String, Object?>.from(decoded);
    final latest = AdminSemVer.tryParse('${map['version'] ?? ''}');
    if (latest == null) {
      return AdminUpdateInfo(
        status: AdminUpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث لا يحتوي رقم إصدار صالح.',
      );
    }
    final abiKey = _androidAbiKey();
    final downloads = map['downloads'];
    final fallbackMap = map['downloadsFallbackGithub'] ?? map['downloadsMirror'];
    final primaryUrl = _pickAdminApkUrl(downloads, abiKey) ?? kMirrorApkUrl;
    final secondaryUrl =
        _pickAdminApkUrl(fallbackMap, abiKey) ?? kDefaultApkUrl;
    final sha256 = _pickAdminSha256(map, abiKey);

    final release = map['releaseUrl'];
    final releaseUrl = (release is String && release.startsWith('https://'))
        ? release
        : kFallbackReleaseUrl;

    final hasNewer = latest > current ||
        (latest.major == current.major &&
            latest.minor == current.minor &&
            latest.patch == current.patch &&
            latest.build > current.build);

    return AdminUpdateInfo(
      status:
          hasNewer ? AdminUpdateStatus.available : AdminUpdateStatus.upToDate,
      current: current,
      latest: latest,
      downloadUrl: primaryUrl,
      fallbackDownloadUrl: secondaryUrl != primaryUrl ? secondaryUrl : kDefaultApkUrl,
      sha256: sha256,
      releaseUrl: releaseUrl,
      notes: '${map['notes'] ?? ''}'.trim(),
    );
  }
}

enum AdminInstallPhase {
  idle,
  awaitingPermission,
  downloading,
  launchingInstaller,
  done,
  failed,
}

class AdminInstallProgress {
  final AdminInstallPhase phase;
  final double? progress;
  final String? error;

  const AdminInstallProgress(this.phase, {this.progress, this.error});
}

class AdminUpdateInstaller {
  static const _channel = MethodChannel('nexora_admin/updates');

  /// يحلّ رابط التحديث إلى رابط الملف الثنائي المباشر (Direct Binary Stream URL)
  /// لتفادي اعتراض تطبيق GitHub عند الحاجة للتنزيل عبر المتصفح.
  static Future<String> resolveDirectBinaryUrl(
    String primaryUrl, {
    String? fallbackUrl,
  }) async {
    final candidates = <String>{
      if (primaryUrl.trim().isNotEmpty) primaryUrl.trim(),
      if (fallbackUrl != null && fallbackUrl.trim().isNotEmpty)
        fallbackUrl.trim(),
      AdminUpdateService.kMirrorApkUrl,
      AdminUpdateService.kDefaultApkUrl,
    }.toList();

    for (final candidate in candidates) {
      final uri = Uri.tryParse(candidate);
      if (uri == null || !uri.isScheme('https')) continue;

      if (uri.host.toLowerCase().endsWith('github.io')) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 4);
        try {
          final req =
              await client.headUrl(uri).timeout(const Duration(seconds: 4));
          final res = await req.close().timeout(const Duration(seconds: 4));
          await res.drain<void>();
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return candidate;
          }
        } catch (_) {
        } finally {
          client.close(force: true);
        }
      }

      if (uri.host.toLowerCase() == 'github.com' &&
          uri.path.contains('/releases/download/')) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);
        try {
          final req =
              await client.getUrl(uri).timeout(const Duration(seconds: 5));
          req.followRedirects = false;
          final res = await req.close().timeout(const Duration(seconds: 5));
          final loc = res.headers.value(HttpHeaders.locationHeader);
          await res.drain<void>();
          if (loc != null && loc.startsWith('https://')) {
            return loc;
          }
        } catch (_) {
        } finally {
          client.close(force: true);
        }
      }
    }

    return primaryUrl.isNotEmpty
        ? primaryUrl
        : AdminUpdateService.kMirrorApkUrl;
  }

  Future<bool> canInstall() async {
    try {
      if (!Platform.isAndroid) return false;
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
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

  Stream<AdminInstallProgress> downloadAndInstall(
    String url, {
    String? fallbackUrl,
  }) async* {
    if (!Platform.isAndroid) {
      yield const AdminInstallProgress(
        AdminInstallPhase.failed,
        error: 'التحديث المباشر متاح على أندرويد فقط.',
      );
      return;
    }

    if (!await canInstall()) {
      yield const AdminInstallProgress(AdminInstallPhase.awaitingPermission);
      await openInstallSettings();
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (await canInstall()) break;
      }
      if (!await canInstall()) {
        yield const AdminInstallProgress(
          AdminInstallPhase.failed,
          error:
              'لم يُمنح إذن تثبيت الحزم. فعّله من إعدادات النظام ثم أعد المحاولة.',
        );
        return;
      }
    }

    yield const AdminInstallProgress(AdminInstallPhase.downloading, progress: 0);

    // نستخدم التنزيل المباشر داخل التطبيق أولاً عبر HTTP Stream مع دعم الروابط البديلة
    // لتجنب تعليق DownloadManager أو فتح المتصفح الخارجي، مع التحقق من سلامة ترويسة ZIP/APK.
    yield* _fallbackHttpDownload(url, fallbackUrl: fallbackUrl);
  }

  Stream<AdminInstallProgress> _fallbackHttpDownload(
    String url, {
    String? fallbackUrl,
  }) async* {
    String dirPath = '/storage/emulated/0/Download/NexoraAdmin';
    try {
      final d = await _channel.invokeMethod<String>('cacheUpdateDir');
      if (d != null && d.isNotEmpty) dirPath = d;
    } catch (_) {}

    final File apk;
    try {
      final dir = Directory(dirPath);
      await dir.create(recursive: true);
      apk = File('${dir.path}/license-admin-update.apk');
      if (apk.existsSync()) {
        try {
          await apk.delete();
        } catch (_) {}
      }
    } catch (e) {
      yield AdminInstallProgress(
        AdminInstallPhase.failed,
        error: 'تعذّر تجهيز مجلد التنزيل: $e',
      );
      return;
    }

    final candidates = <String>{
      if (url.trim().isNotEmpty) url.trim(),
      if (fallbackUrl != null && fallbackUrl.trim().isNotEmpty)
        fallbackUrl.trim(),
      AdminUpdateService.kMirrorApkUrl,
      AdminUpdateService.kDefaultApkUrl,
    }.toList();

    String? lastError;

    for (final candidateUrl in candidates) {
      final client = http.Client();
      IOSink? sink;
      var downloadedOk = false;
      try {
        if (apk.existsSync()) {
          try {
            await apk.delete();
          } catch (_) {}
        }
        final req = http.Request('GET', Uri.parse(candidateUrl));
        req.headers['Cache-Control'] = 'no-cache';
        final res = await client.send(req).timeout(const Duration(seconds: 25));
        if (res.statusCode < 200 || res.statusCode >= 300) {
          lastError = 'الخادم أعاد الرمز ${res.statusCode}.';
          continue;
        }
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
            yield AdminInstallProgress(
              AdminInstallPhase.downloading,
              progress: (total != null && total > 0)
                  ? (received / total).clamp(0.0, 1.0)
                  : null,
            );
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (apk.existsSync() && apk.lengthSync() > 1024 * 1024) {
          downloadedOk = true;
        } else {
          lastError = 'الملف المنزَّل غير مكتمل.';
        }
      } catch (e) {
        lastError = '$e';
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
        client.close();
      }

      if (downloadedOk) {
        yield* _install(apk.path);
        return;
      }
    }

    // في حال تعذر التنزيل المباشر عبر HTTP، نجرب DownloadManager كمسار احتياطي أخير
    int? dmId;
    try {
      final r =
          await _channel.invokeMethod<Object?>('startDownload', {'url': url});
      final started = (r is int) ? r : int.tryParse('$r') ?? -1;
      if (started >= 0) dmId = started;
    } catch (_) {}

    if (dmId != null) {
      var stuckCount = 0;
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final st = await _query(dmId);
        final status = '${st['status']}';
        final bytes = (st['bytes'] as num?)?.toInt() ?? 0;
        final total = (st['total'] as num?)?.toInt() ?? -1;
        switch (status) {
          case 'done':
            final path = '${st['path']}';
            if (path.isNotEmpty) {
              yield* _install(path);
              return;
            }
            break;
          case 'failed':
            yield AdminInstallProgress(
              AdminInstallPhase.failed,
              error: lastError ?? 'فشل تنزيل التحديث. تحقق من الاتصال.',
            );
            return;
          case 'unknown':
            if (++stuckCount >= 10) {
              yield AdminInstallProgress(
                AdminInstallPhase.failed,
                error: lastError ?? 'تعذّر إكمال التنزيل. أعد المحاولة.',
              );
              return;
            }
            break;
          default:
            stuckCount = 0;
            yield AdminInstallProgress(
              AdminInstallPhase.downloading,
              progress: (total > 0) ? bytes / total : null,
            );
        }
      }
    }

    yield AdminInstallProgress(
      AdminInstallPhase.failed,
      error: 'فشل التنزيل: ${lastError ?? "تحقق من اتصال الإنترنت"}',
    );
  }

  Stream<AdminInstallProgress> _install(String path) async* {
    final apk = File(path);
    if (!apk.existsSync() || apk.lengthSync() < 1024 * 1024) {
      yield const AdminInstallProgress(
        AdminInstallPhase.failed,
        error: 'الملف المنزَّل غير مكتمل. أعد المحاولة.',
      );
      return;
    }
    // التحقق من ترويسة ملف APK (ZIP Magic Bytes: PK\x03\x04) لضمان عدم تمرير صفحة HTML أو ملف تالف لمثبت النظام
    try {
      final header = await apk.openRead(0, 4).first;
      if (header.length < 4 ||
          header[0] != 0x50 ||
          header[1] != 0x4B ||
          header[2] != 0x03 ||
          header[3] != 0x04) {
        try {
          await apk.delete();
        } catch (_) {}
        yield const AdminInstallProgress(
          AdminInstallPhase.failed,
          error: 'الملف المنزَّل ليس حزمة أندرويد صالحة. أعد المحاولة.',
        );
        return;
      }
    } catch (_) {
      yield const AdminInstallProgress(
        AdminInstallPhase.failed,
        error: 'تعذّر قراءة حزمة التحديث المنزَّلة.',
      );
      return;
    }

    yield const AdminInstallProgress(
      AdminInstallPhase.launchingInstaller,
      progress: 1,
    );
    try {
      final r =
          await _channel.invokeMethod<String>('installApk', {'path': path});
      if (r == 'ok') {
        yield const AdminInstallProgress(AdminInstallPhase.done, progress: 1);
      } else {
        yield AdminInstallProgress(
          AdminInstallPhase.failed,
          error: 'تعذّر فتح شاشة التثبيت ($r).',
        );
      }
    } catch (e) {
      yield AdminInstallProgress(
        AdminInstallPhase.failed,
        error: 'تعذّر فتح شاشة التثبيت: $e',
      );
    }
  }
}

/// يبدأ التحديث المباشر داخل التطبيق (In-App One-Click Update) دون التحويل للمتصفح.
Future<void> startAdminOneClickUpdate(
  BuildContext context,
  AdminUpdateInfo info,
) async {
  final url = info.downloadUrl ?? AdminUpdateService.kMirrorApkUrl;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AdminOneClickUpdateDialog(url: url, info: info),
  );
}

class _AdminOneClickUpdateDialog extends StatefulWidget {
  final String url;
  final AdminUpdateInfo info;
  const _AdminOneClickUpdateDialog({required this.url, required this.info});

  @override
  State<_AdminOneClickUpdateDialog> createState() =>
      _AdminOneClickUpdateDialogState();
}

class _AdminOneClickUpdateDialogState
    extends State<_AdminOneClickUpdateDialog> {
  final _installer = AdminUpdateInstaller();
  AdminInstallProgress _state =
      const AdminInstallProgress(AdminInstallPhase.idle);
  StreamSubscription<AdminInstallProgress>? _sub;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _sub?.cancel();
    setState(() =>
        _state = const AdminInstallProgress(AdminInstallPhase.downloading));
    _sub = _installer
        .downloadAndInstall(
      widget.url,
      fallbackUrl: widget.info.fallbackDownloadUrl,
    )
        .listen(
      (p) {
        if (!mounted) return;
        setState(() => _state = p);
        if (p.phase == AdminInstallPhase.done) {
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) Navigator.of(context).pop();
          });
        }
      },
      onError: (Object e, StackTrace _) {
        if (!mounted) return;
        setState(() => _state = AdminInstallProgress(
              AdminInstallPhase.failed,
              error: 'تعذّر تنزيل التحديث: $e',
            ));
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = switch (_state.phase) {
      AdminInstallPhase.awaitingPermission => (
          'إذن مطلوب لمرة واحدة',
          'فعّل «السماح من هذا المصدر» في الشاشة التي فُتحت، ثم عد إلى تطبيق التراخيص وسيتابع التحديث تلقائياً.',
        ),
      AdminInstallPhase.downloading => (
          'جارٍ تنزيل تحديث مدير التراخيص…',
          _state.progress != null
              ? '${(_state.progress! * 100).round()}٪ — التنزيل يتم مباشرة داخل التطبيق'
              : 'جارٍ الاتصال بخادم التحديثات السريع…',
        ),
      AdminInstallPhase.launchingInstaller || AdminInstallPhase.done => (
          'اكتمل التنزيل ✅',
          'اضغط «تثبيت» في شاشة النظام لإتمام تحديث تطبيق التراخيص.',
        ),
      AdminInstallPhase.failed => ('تعذّر التحديث', _state.error ?? ''),
      AdminInstallPhase.idle => ('لحظة…', ''),
    };
    final failed = _state.phase == AdminInstallPhase.failed;
    final downloading = _state.phase == AdminInstallPhase.downloading;

    return PopScope(
      canPop: failed || downloading,
      child: AlertDialog(
        icon: Icon(
          failed ? Icons.error_outline : Icons.system_update_alt_rounded,
          color: failed ? Colors.red : const Color(0xFF7C3AED),
        ),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(subtitle, style: const TextStyle(height: 1.6)),
            if (downloading) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _state.progress),
            ],
          ],
        ),
        actions: [
          if (downloading)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إخفاء النافذة'),
            ),
          if (failed) ...[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إغلاق'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final directUrl =
                    await AdminUpdateInstaller.resolveDirectBinaryUrl(
                  widget.url,
                  fallbackUrl: widget.info.fallbackDownloadUrl,
                );
                final uri = Uri.tryParse(directUrl);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('تنزيل مباشر'),
            ),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ],
      ),
    );
  }
}

/// نافذة فحص وتثبيت تحديث تطبيق مدير التراخيص (تُفتح من شريط العنوان أو تلقائياً).
Future<void> showAdminUpdateDialog(
  BuildContext context, {
  AdminUpdateInfo? initialInfo,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _AdminUpdateCheckDialog(initialInfo: initialInfo),
  );
}

class _AdminUpdateCheckDialog extends StatefulWidget {
  final AdminUpdateInfo? initialInfo;
  const _AdminUpdateCheckDialog({this.initialInfo});

  @override
  State<_AdminUpdateCheckDialog> createState() =>
      _AdminUpdateCheckDialogState();
}

class _AdminUpdateCheckDialogState extends State<_AdminUpdateCheckDialog> {
  AdminUpdateInfo? _info;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialInfo != null) {
      _info = widget.initialInfo;
    } else {
      _check();
    }
  }

  Future<void> _check() async {
    setState(() => _loading = true);
    final res = await AdminUpdateService().check();
    if (!mounted) return;
    setState(() {
      _info = res;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.system_update_alt_rounded, color: Color(0xFF7C3AED)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'تحديثات مدير التراخيص',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline),
              title: const Text('الإصدار الحالي لتطبيق التراخيص'),
              subtitle: Text(AdminSemVer.current.toString()),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              )
            else if (info != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (info.status) {
                      AdminUpdateStatus.upToDate => Icons.verified_outlined,
                      AdminUpdateStatus.available =>
                        Icons.system_update_alt_rounded,
                      AdminUpdateStatus.unknown => Icons.wifi_off_outlined,
                    },
                    color: switch (info.status) {
                      AdminUpdateStatus.upToDate => Colors.green,
                      AdminUpdateStatus.available => const Color(0xFF7C3AED),
                      AdminUpdateStatus.unknown => Colors.grey,
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.headline,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          switch (info.status) {
                            AdminUpdateStatus.upToDate =>
                              'أنت تستخدم أحدث نسخة من تطبيق مدير التراخيص (${info.latest ?? info.current}).',
                            AdminUpdateStatus.available =>
                              'الإصدار الجديد المتاح: ${info.latest}',
                            AdminUpdateStatus.unknown =>
                              info.error ?? 'تحقّق من الاتصال ثم أعد المحاولة.',
                          },
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (info.hasUpdate && info.notes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    info.notes,
                    style: const TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                ),
              ],
              if (info.hasUpdate) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    startAdminOneClickUpdate(context, info);
                  },
                  icon: const Icon(Icons.download_rounded),
                  label: Text('تحديث داخل التطبيق الآن (${info.latest})'),
                ),
              ],
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _loading ? null : _check,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('التحقق الآن'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}

/// بطاقة تحديث تطبيق التراخيص لعرضها داخل تبويب «مركز التحكم».
class AdminSelfUpdateCard extends StatefulWidget {
  const AdminSelfUpdateCard({super.key});

  @override
  State<AdminSelfUpdateCard> createState() => _AdminSelfUpdateCardState();
}

class _AdminSelfUpdateCardState extends State<AdminSelfUpdateCard> {
  AdminUpdateInfo? _info;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _loading = true);
    final res = await AdminUpdateService().check();
    if (!mounted) return;
    setState(() {
      _info = res;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.admin_panel_settings_rounded,
                    color: Color(0xFF7C3AED)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '🔄 تحديث تطبيق مدير التراخيص (الموحّد)',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'v$adminFullVersion',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF7C3AED),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ),
              )
            else if (info != null) ...[
              Text(
                switch (info.status) {
                  AdminUpdateStatus.upToDate =>
                    '✅ تطبيق مدير التراخيص محدَّث إلى آخر إصدار (${info.latest ?? info.current}).',
                  AdminUpdateStatus.available =>
                    '⬆️ يتوفّر إصدار جديد لتطبيق التراخيص: ${info.latest}',
                  AdminUpdateStatus.unknown =>
                    '⚠️ ${info.error ?? "تعذّر التحقق من التحديثات."}',
                },
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: switch (info.status) {
                    AdminUpdateStatus.upToDate => Colors.green.shade700,
                    AdminUpdateStatus.available => const Color(0xFF7C3AED),
                    AdminUpdateStatus.unknown => Colors.orange.shade800,
                  },
                ),
              ),
              if (info.hasUpdate && info.notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  info.notes,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _check,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('التحقق الآن'),
                  ),
                ),
                if (info != null && info.hasUpdate) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => startAdminOneClickUpdate(context, info),
                      icon: const Icon(Icons.system_update_alt_rounded,
                          size: 16),
                      label: Text('تحديث (${info.latest})'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
