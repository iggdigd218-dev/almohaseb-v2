// إدارة معرّف الجهاز الثابت + بصمة العتاد الحتمية.
// deviceId يُشتق من بصمة عتاد الجهاز (device_info_plus) بحيث تنتج نفس
// الهوية بعد حذف التطبيق وإعادة تثبيته — يمنع «الأشباح» في قائمة الأجهزة:
// إعادة الانضمام تُحيي السجل القديم بدوره وصلاحياته بدل إنشاء جهاز مكرر.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../repository.dart';
import '../../core/database.dart';
import '../../core/platform_info.dart';

const _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const _deviceIdKey = 'sync.deviceId';
const _deviceNameKey = 'sync.deviceName';
const _hwFingerprintKey = 'sync.hwFingerprint';

/// مفاتيح التخزين المستديم الموحد لمعرّف الجهاز وبصمته العتادية عبر الجلسات والحسابات.
const String kPersistentDeviceIdPrefKey = 'nexora.persistent.device_id.v1';
const String kPersistentHwFingerprintPrefKey =
    'nexora.persistent.hw_fingerprint_raw.v1';

/// يولّد سلسلة عشوائية من 8 أحرف من قاعدة Base32 مبسطة.
String generateDeviceCode([int len = 8]) {
  final rnd = Random.secure();
  return List.generate(len, (_) => _chars[rnd.nextInt(_chars.length)]).join();
}

String formatDeviceId(String code) => 'DEVICE-$code';

/// يحوّل تجزئة SHA-256 إلى رمز Base32 مبسط بطول [len] — نفس أبجدية
/// generateDeviceCode حتى تبقى المعرفات متجانسة الشكل.
String _hashToCode(String input, [int len = 12]) {
  final digest = sha256.convert(utf8.encode(input)).bytes;
  final buf = StringBuffer();
  for (var i = 0; i < len; i++) {
    buf.write(_chars[digest[i % digest.length] % _chars.length]);
  }
  return buf.toString();
}

String? Function()? debugHardwareFingerprintOverride;

String? _cachedHardwareFingerprintRaw;

/// يجمع معرفات العتاد الثابتة للمنصة الحالية عبر device_info_plus.
/// يعيد null إن تعذر الجمع (بيئة اختبار VM بلا plugin) — عندها نتراجع
/// للمعرف المحفوظ أو العشوائي.
Future<String?> hardwareFingerprintRaw() async {
  if (debugHardwareFingerprintOverride != null) {
    return debugHardwareFingerprintOverride!();
  }
  if (_cachedHardwareFingerprintRaw != null &&
      _cachedHardwareFingerprintRaw!.trim().isNotEmpty) {
    return _cachedHardwareFingerprintRaw;
  }
  try {
    final plugin = DeviceInfoPlugin();
    String? resolved;
    if (PlatformInfo.isAndroid) {
      final a = await plugin.androidInfo
          .timeout(const Duration(seconds: 3));
      // (تدعيم البصمة) مكوّنات عتادية ثابتة لنفس الجهاز الفعلي حتى بعد
      // مسح بيانات التطبيق أو إعادة تثبيته أو تبديل الحسابات:
      //  • ANDROID_ID (androidId / a.id): ثابت عبر الجلسات والحسابات.
      //  • مقدمة a.fingerprint الثابتة (brand/product/device قبل «:»).
      //  • hardware + model + board: صفات لوحة وعتاد مصنعية لا تتبدل.
      final dataMap = a.data;
      final androidId =
          '${dataMap['androidId'] ?? dataMap['id'] ?? a.id}'.trim();
      final fpRaw = a.fingerprint;
      final fpStable =
          fpRaw.contains(':') ? fpRaw.substring(0, fpRaw.indexOf(':')) : fpRaw;
      final parts = [
        androidId.isNotEmpty ? androidId : a.id,
        fpStable,
        a.hardware,
        a.model,
        a.board,
      ];
      resolved = 'android:${parts.join('|')}';
    } else if (PlatformInfo.isWindows) {
      final w = await plugin.windowsInfo
          .timeout(const Duration(seconds: 3));
      // deviceId = MachineGuid — ثابت عبر إعادة تثبيت التطبيق.
      resolved = 'windows:${w.deviceId}|${w.computerName}';
    } else if (PlatformInfo.isLinux) {
      final l = await plugin.linuxInfo
          .timeout(const Duration(seconds: 3));
      // machineId من /etc/machine-id — ثابت للنظام.
      resolved = 'linux:${l.machineId ?? l.id}|${l.name}';
    } else if (PlatformInfo.isMacOS) {
      final m = await plugin.macOsInfo
          .timeout(const Duration(seconds: 3));
      resolved = 'macos:${m.systemGUID ?? m.computerName}';
    } else if (PlatformInfo.isIOS) {
      final i =
          await plugin.iosInfo.timeout(const Duration(seconds: 3));
      resolved = 'ios:${i.identifierForVendor ?? i.utsname.machine}';
    }
    if (resolved != null && resolved.trim().isNotEmpty) {
      _cachedHardwareFingerprintRaw = resolved;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(kPersistentHwFingerprintPrefKey, resolved);
      } catch (_) {}
      return resolved;
    }
  } catch (_) {
    // بيئة اختبار أو منصة بلا device_info — نحاول استرجاع البصمة المحفوظة.
  }
  try {
    final prefs = await SharedPreferences.getInstance();
    final savedRaw =
        (prefs.getString(kPersistentHwFingerprintPrefKey) ?? '').trim();
    if (savedRaw.isNotEmpty) {
      _cachedHardwareFingerprintRaw = savedRaw;
      return savedRaw;
    }
  } catch (_) {}
  return null;
}

/// معرف الجهاز المشتق من بصمة العتاد: DEVICE-<12 حرفاً حتمياً>.
/// نفس الجهاز يعيد إنتاج نفس المعرف بعد أي إعادة تثبيت أو تبديل حساب.
Future<String?> deterministicDeviceId() async {
  final raw = await hardwareFingerprintRaw();
  if (raw == null || raw.trim().isEmpty) return null;
  return formatDeviceId(_hashToCode(raw));
}

/// يضمن إرجاع بصمة الجهاز الموحدة (24 حرفاً) وحفظها في الإعدادات.
Future<String> ensureHardwareFingerprintHash(Repo repo) async {
  final st = await repo.settings();
  final existingFp = (st[_hwFingerprintKey] ?? '').trim();
  final raw = await hardwareFingerprintRaw();
  if (raw != null && raw.trim().isNotEmpty) {
    final computed = _hashToCode(raw, 24);
    if (existingFp != computed) {
      await repo.setSetting(_hwFingerprintKey, computed);
    }
    return computed;
  }
  if (existingFp.isNotEmpty) return existingFp;
  final devId = (st[_deviceIdKey] ?? '').trim();
  if (devId.isNotEmpty) {
    final fallback = _hashToCode('persisted:$devId', 24);
    await repo.setSetting(_hwFingerprintKey, fallback);
    return fallback;
  }
  return '';
}

/// يُعيد deviceId الثابت والموحد لهذا الجهاز.
/// الأولوية:
/// (1) المعرف المحفوظ في قاعدة البيانات أو التخزين المستديم (SharedPreferences)
///     أو المشتق من البصمة العتادية (androidId) بحيث لا يتغير ولا يتولد معرّف جديد
///     عند تسجيل الخروج أو تبديل الحسابات.
/// (2) التراجع العشوائي في بيئات الاختبار المعزولة.
Future<String> ensureDeviceId(Repo repo) async {
  final st = await repo.settings();
  final existing = (st[_deviceIdKey] ?? '').trim();
  final useGlobalStorage =
      !repo.hasCustomDatabaseProvider && debugHardwareFingerprintOverride == null;

  SharedPreferences? prefs;
  if (useGlobalStorage) {
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
  }

  final raw = await hardwareFingerprintRaw();
  final hwId = (raw != null && raw.trim().isNotEmpty)
      ? formatDeviceId(_hashToCode(raw))
      : null;
  final hwFpHash = (raw != null && raw.trim().isNotEmpty)
      ? _hashToCode(raw, 24)
      : null;

  if (existing.isNotEmpty) {
    if (hwFpHash != null && (st[_hwFingerprintKey] ?? '').trim() != hwFpHash) {
      await repo.setSetting(_hwFingerprintKey, hwFpHash);
    } else if ((st[_hwFingerprintKey] ?? '').trim().isEmpty) {
      await repo.setSetting(
          _hwFingerprintKey, _hashToCode('persisted:$existing', 24));
    }
    if (prefs != null) {
      try {
        if ((prefs.getString(kPersistentDeviceIdPrefKey) ?? '').trim().isEmpty) {
          await prefs.setString(kPersistentDeviceIdPrefKey, existing);
        }
      } catch (_) {}
    }
    return existing;
  }

  final globalSavedId =
      (prefs?.getString(kPersistentDeviceIdPrefKey) ?? '').trim();
  final fresh = hwId ??
      (globalSavedId.isNotEmpty
          ? globalSavedId
          : formatDeviceId(generateDeviceCode()));

  await repo.setSetting(_deviceIdKey, fresh);
  final effectiveFpHash = hwFpHash ?? _hashToCode('persisted:$fresh', 24);
  await repo.setSetting(_hwFingerprintKey, effectiveFpHash);

  if (prefs != null) {
    try {
      await prefs.setString(kPersistentDeviceIdPrefKey, fresh);
    } catch (_) {}
  }
  return fresh;
}

/// اعتماد معرّف جهاز مسجل مسبقاً في مساحة العمل لنفس بصمة الهاتف
/// لمنع إنشاء جهاز مكرر أو زيادة عداد الأجهزة عند إعادة الربط أو تبديل الحساب.
Future<String> adoptCanonicalDeviceId(
  Repo repo,
  String canonicalId, {
  String? fingerprint,
}) async {
  final cleanId = canonicalId.trim();
  if (cleanId.isEmpty) return ensureDeviceId(repo);
  final st = await repo.settings();
  final oldId = (st[_deviceIdKey] ?? '').trim();
  await repo.setSetting(_deviceIdKey, cleanId);
  repo.updateCachedDeviceId(cleanId);
  if (fingerprint != null && fingerprint.trim().isNotEmpty) {
    await repo.setSetting(_hwFingerprintKey, fingerprint.trim());
  }
  if (!repo.hasCustomDatabaseProvider &&
      debugHardwareFingerprintOverride == null) {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kPersistentDeviceIdPrefKey, cleanId);
    } catch (_) {}
  }
  if (oldId.isNotEmpty && oldId != cleanId) {
    try {
      final db = await repo.database;
      final rows = await db.query(
        'devices',
        where: 'id = ?',
        whereArgs: [oldId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final updatedRow = Map<String, Object?>.from(rows.first);
        updatedRow['id'] = cleanId;
        await AppDatabase.ensureWorkspaceRow(
            db, '${updatedRow['workspace_id'] ?? ''}');
        await db.insert(
          'devices',
          updatedRow,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await db.delete('devices', where: 'id = ?', whereArgs: [oldId]);
      }
    } catch (_) {}
  }
  return cleanId;
}

Future<String?> getDeviceIdCached(Repo repo) async {
  final st = await repo.settings();
  return st[_deviceIdKey];
}

Future<void> setDeviceName(Repo repo, String name) =>
    repo.setSetting(_deviceNameKey, name);

/// الاسم الافتراضي الموحّد لأي جهاز/مستخدم جديد لم يحدد اسماً بعد.
/// (توحيد الهوية: يظهر نفسه في لوحة المدير والقوائم والإشعارات.)
const String kDefaultMemberName = 'مستخدم جديد';

Future<String> deviceName(Repo repo) async {
  final st = await repo.settings();
  final n = st[_deviceNameKey];
  if (n != null && n.trim().isNotEmpty) return n;
  // الاسم الافتراضي الموحّد — لا أسماء عتاد ولا أسماء متفرقة.
  return kDefaultMemberName;
}
