import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../core/app_version.dart';
import '../core/database.dart';
import '../core/desktop_net.dart';
import '../core/format.dart';
import '../core/media_paths.dart';
import 'repository.dart';
import 'sync/subscription_guard.dart';
import 'sync/sync_diagnostics.dart';
import 'sync/sync_engine.dart';

/// استثناء مخصص لعمليات النسخ الاحتياطي والاستعادة.
class BackupRestoreException extends BackupImportException {
  const BackupRestoreException(super.message);
}

/// يُرمى عند محاولة استعادة نسخة تنتمي لمنشأة أخرى غير المنشأة الحالية.
class BackupWorkspaceMismatchException extends BackupRestoreException {
  final String backupWorkspaceId;
  final String currentWorkspaceId;

  const BackupWorkspaceMismatchException({
    required this.backupWorkspaceId,
    required this.currentWorkspaceId,
  }) : super(
          'هوية المنشأة في النسخة الاحتياطية ($backupWorkspaceId) '
          'لا تطابق هوية المنشأة الحالية ($currentWorkspaceId).',
        );
}

/// يُرمى عند محاولة استعادة نسخة أقدم من البيانات الحالية دون تأكيد صريح من المدير.
class BackupOutdatedConflictException extends BackupRestoreException {
  final DateTime backupTime;
  final DateTime currentLastTxTime;
  final String warningMessage;

  BackupOutdatedConflictException({
    required this.backupTime,
    required this.currentLastTxTime,
  })  : warningMessage = buildCriticalWarningMessage(
          backupTime: backupTime,
          currentLastTxTime: currentLastTxTime,
        ),
        super(
          buildCriticalWarningMessage(
            backupTime: backupTime,
            currentLastTxTime: currentLastTxTime,
          ),
        );

  static String _safeFormatDateTime(DateTime dt) {
    final local = dt.toLocal();
    try {
      return Fmt.dateTime(local);
    } catch (_) {
      String two(int n) => n.toString().padLeft(2, '0');
      return '${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}:${two(local.minute)}';
    }
  }

  static String buildCriticalWarningMessage({
    required DateTime backupTime,
    required DateTime currentLastTxTime,
  }) {
    final x = _safeFormatDateTime(backupTime);
    final y = _safeFormatDateTime(currentLastTxTime);
    return 'تحذير مالي حرج: النسخة التي تحاول استعادتها أقدم من بياناتك الحالية. '
        'تاريخ النسخة: [$x] مقابل تاريخ أحدث حركة حالية: [$y]. '
        'الاستمرار سيؤدي لفقدان العمليات المسجلة بعد تاريخ النسخة.';
  }
}

/// نموذج ملف الوصف `manifest.json` داخل حزمة `.nexora`.
class BackupManifest {
  final String app;
  final String version;
  final String workspaceId;
  final String createdAt;
  final int schemaVersion;
  final String lastTransactionTime;
  final Map<String, Map<String, String>> mediaFiles;

  const BackupManifest({
    required this.app,
    required this.version,
    required this.workspaceId,
    required this.createdAt,
    required this.schemaVersion,
    required this.lastTransactionTime,
    this.mediaFiles = const {},
  });

  DateTime? get createdAtDate => DateTime.tryParse(createdAt);

  DateTime? get lastTransactionDate =>
      lastTransactionTime.trim().isEmpty
          ? null
          : DateTime.tryParse(lastTransactionTime);

  /// التاريخ المرجعي للمقارنة مع أحدث حركة محلية.
  DateTime? get effectiveComparisonDate =>
      lastTransactionDate ?? createdAtDate;

  Map<String, Object?> toJson() => {
        'app': app,
        'version': version,
        'workspace_id': workspaceId,
        'created_at': createdAt,
        'schema_version': schemaVersion,
        'last_transaction_time': lastTransactionTime,
        if (mediaFiles.isNotEmpty) 'media_files': mediaFiles,
      };

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    final appVal = '${json['app'] ?? ''}'.trim();
    if (appVal.toLowerCase() != 'nexora') {
      throw const BackupRestoreException(
        'ملف manifest.json غير صالح أو لا ينتمي لتطبيق Nexora.',
      );
    }
    final parsedMedia = <String, Map<String, String>>{};
    final rawMedia = json['media_files'];
    if (rawMedia is Map) {
      rawMedia.forEach((k, v) {
        if (v is Map) {
          parsedMedia['$k'] = <String, String>{
            for (final e in v.entries) '${e.key}': '${e.value ?? ''}',
          };
        }
      });
    }
    return BackupManifest(
      app: appVal,
      version: '${json['version'] ?? kAppVersion}'.trim(),
      workspaceId: '${json['workspace_id'] ?? json['workspaceId'] ?? ''}'.trim(),
      createdAt: '${json['created_at'] ?? ''}'.trim(),
      schemaVersion: (json['schema_version'] as num?)?.toInt() ??
          (json['db_version'] as num?)?.toInt() ??
          AppDatabase.schemaVersion,
      lastTransactionTime:
          '${json['last_transaction_time'] ?? ''}'.trim(),
      mediaFiles: parsedMedia,
    );
  }
}

/// نتيجة فحص وفك ضغط حزمة `.nexora` مؤقتاً قبل الاستعادة.
class BackupInspectionResult {
  final BackupManifest manifest;
  final File? extractedDbFile;
  final Directory? extractedMediaDir;
  final Map<String, Object?>? legacyJsonPayload;
  final Directory? tempDir;
  final DateTime? localLastTransactionTime;
  final DateTime? backupComparisonTime;
  final bool isOutdated;
  final bool dateReadFailed;

  const BackupInspectionResult({
    required this.manifest,
    this.extractedDbFile,
    this.extractedMediaDir,
    this.legacyJsonPayload,
    this.tempDir,
    this.localLastTransactionTime,
    this.backupComparisonTime,
    required this.isOutdated,
    this.dateReadFailed = false,
  });

  bool get isOlderThanLocal => isOutdated;

  /// رسالة التحذير المالي الحرج إذا كانت النسخة أقدم من البيانات الحالية.
  String get criticalWarningMessage {
    final bTime =
        backupComparisonTime ?? manifest.effectiveComparisonDate ?? DateTime.now();
    final cTime = localLastTransactionTime ?? DateTime.now();
    return BackupOutdatedConflictException.buildCriticalWarningMessage(
      backupTime: bTime,
      currentLastTxTime: cTime,
    );
  }

  /// تنظيف الملفات المؤقتة بعد انتهاء الفحص أو الإلغاء.
  Future<void> dispose() async {
    final dir = tempDir;
    if (dir != null && await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> cleanup() => dispose();
}

/// نتيجة عملية الاستعادة المكتملة.
class BackupRestoreResult {
  final BackupManifest manifest;
  final File safetySnapshotFile;
  final int restoredRecordsCount;

  const BackupRestoreResult({
    required this.manifest,
    required this.safetySnapshotFile,
    required this.restoredRecordsCount,
  });

  int get restoredRecords => restoredRecordsCount;
}

/// محرك النسخ الاحتياطي والاستعادة المتكامل (.nexora).
class BackupEngine {
  BackupEngine._();

  /// اسم ملف لقطة الأمان التلقائية قبل الاستعادة.
  static const String kSafetySnapshotBaseName = 'Safety_Snapshot_Before_Restore';
  static const String safetySnapshotPrefix = kSafetySnapshotBaseName;

  /// رسالة التنبيه القياسية عند تعطيل الاستعادة أثناء المزامنة السحابية النشطة.
  static const String kActiveSyncRestoreBlockedMessage =
      'الاستعادة معطلة حالياً لوجود مزامنة سحابية نشطة لمنع تضارب البيانات. '
      'الاستعادة مخصصة لحالات العمل غير المتصل (Offline) أو انتهاء الاشتراك.';
  static const String syncActiveRestoreDisabledMessage =
      kActiveSyncRestoreBlockedMessage;

  /// ترويسة ملفات SQLite 3 القياسية (16 بايت: "SQLite format 3\x00").
  static const List<int> _sqliteMagicHeader = <int>[
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
    0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
  ];

  static bool _hasValidSqliteHeader(List<int> bytes) {
    if (bytes.length < _sqliteMagicHeader.length) return false;
    for (var i = 0; i < _sqliteMagicHeader.length; i++) {
      if (bytes[i] != _sqliteMagicHeader[i]) return false;
    }
    return true;
  }

  /// تجاوز اختباري لحالة المزامنة النشطة.
  static bool? debugForceCloudSyncActive;

  /// تجاوز اختباري لمجلد النسخ الاحتياطية المحلي.
  static Directory? debugBackupsDirectoryOverride;

  /// 1. فحص صلاحية الوصول للنسخ الاحتياطي والاستعادة:
  /// متاح حصراً لحساب مدير المنشأة (Owner / Admin) والحساب الفردي،
  /// ومحجوب بالكامل عن الكاشير والموظفين.
  static Future<bool> canAccessBackupAndRestore(Repo repo) =>
      repo.canAccessBackupAndRestore();

  /// 2. فحص ما إذا كانت المزامنة السحابية المباشرة نشطة حالياً:
  /// أثناء تشغيل المزامنة السحابية المباشرة يُسمح فقط بإنشاء نسخة جديدة،
  /// ويُحظر استيراد/استعادة أي نسخة لمنع تضارب البيانات.
  static Future<bool> isLiveCloudSyncActive(
    Repo repo, {
    SyncEngine? engine,
    SyncEngine? syncEngine,
    SubscriptionState? sub,
  }) async {
    final effectiveEngine = engine ?? syncEngine;
    if (debugForceCloudSyncActive != null) {
      return debugForceCloudSyncActive!;
    }
    if (effectiveEngine != null) {
      if (!effectiveEngine.isCloudSyncActive) return false;
    }
    // فحص انقطاع الاتصال الفعلي: لا نمنع المستخدم من الاستعادة أوفلاين
    final diag = SyncDiagnostics.instance.snapshot;
    if (DesktopNet.netErrorNotifier.value != null ||
        diag.lastPullFault == SyncFaultSource.network ||
        diag.lastPushFault == SyncFaultSource.network) {
      return false;
    }
    final effectiveSub = sub ?? SubscriptionGuard.lastState;
    if (effectiveSub.expired || effectiveSub.isFrozen || !effectiveSub.isActive) {
      return false;
    }
    if (effectiveEngine != null) {
      return effectiveEngine.isCloudSyncActive;
    }
    try {
      final st = await repo.settings();
      if ((st['account.type'] ?? '').trim() == 'individual') {
        return false;
      }
      final settingMode = (st['workspace.mode'] ?? '').trim();
      final mode = settingMode.isNotEmpty ? settingMode : await repo.workspaceMode();
      if (mode == 'standalone') {
        return false;
      }
      // عدم الاعتماد على الرابط الافتراضي الساكن؛ يتطلب وجود رابط مهيأ فعلياً في الإعدادات
      final configuredUrl = (st['cloudBackendUrl'] ?? '').trim();
      if (configuredUrl.isEmpty) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// صياغة اسم ملف النسخة الاحتياطية بالتاريخ والوقت الدقيق:
  /// مثل: `MyAccounts_Auto_V2_11-Oct-2026 07:38:25.nexora`
  static String formatBackupFileName({
    bool auto = false,
    DateTime? timestamp,
    bool forFileSystem = false,
  }) {
    final dt = (timestamp ?? DateTime.now()).toLocal();
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final day = two(dt.day);
    final mon = months[(dt.month - 1).clamp(0, 11)];
    final year = dt.year;
    final sep = forFileSystem ? '-' : ':';
    final timePart = '${two(dt.hour)}$sep${two(dt.minute)}$sep${two(dt.second)}';
    final kind = auto ? 'Auto' : 'Backup';
    return 'MyAccounts_${kind}_V2_$day-$mon-$year $timePart.nexora';
  }

  /// مجلد حفظ النسخ ولقطات الأمان المحلية.
  static Future<Directory> backupsDirectory() async {
    if (debugBackupsDirectoryOverride != null) {
      await debugBackupsDirectoryOverride!.create(recursive: true);
      return debugBackupsDirectoryOverride!;
    }
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'backups'));
    await dir.create(recursive: true);
    return dir;
  }

  /// 3. إنشاء حزمة محمية مضغوطة (.nexora) بصيغة Gzip:
  /// تتكون من:
  /// - `database.db`: مستخرجة عبر `VACUUM INTO` لدمج ملفات WAL المؤقتة بدون أي تلف.
  /// - `manifest.json`: يحتوي هوية المنشأة، الإصدار، إصدار المخطط، وتاريخ أحدث حركة.
  static Future<File> createNexoraPackage(
    Repo repo, {
    File? targetFile,
    Directory? outputDirectory,
    String? customFileName,
    bool isAuto = false,
    bool auto = false,
    bool isSafetySnapshot = false,
  }) async {
    final effectiveAuto = isAuto || auto;
    if (!isSafetySnapshot && !effectiveAuto) {
      if (!await canAccessBackupAndRestore(repo)) {
        throw const BackupRestoreException(
          'عمليات النسخ الاحتياطي متاحة حصراً لمدير المنشأة أو الحساب الفردي.',
        );
      }
    }

    final db = await repo.database;
    final workspaceId = await repo.activeWorkspaceId();
    final lastTx = await repo.latestTransactionTime();
    final nowUtc = DateTime.now().toUtc();

    final tempWorkDir =
        await Directory.systemTemp.createTemp('nexora_pkg_build_');
    try {
      final vacuumDbPath = p.join(tempWorkDir.path, 'database.db');
      final vacuumDbFile = File(vacuumDbPath);
      if (await vacuumDbFile.exists()) {
        await vacuumDbFile.delete();
      }

      // 1) استخراج نسخة نظيفة ومدمجة بالكامل عبر استعلام VACUUM INTO
      var vacuumSucceeded = false;
      try {
        final escapedPath = vacuumDbPath.replaceAll("'", "''");
        await db.execute("VACUUM INTO '$escapedPath'");
        vacuumSucceeded =
            await vacuumDbFile.exists() && await vacuumDbFile.length() > 0;
      } catch (_) {
        vacuumSucceeded = false;
      }

      if (!vacuumSucceeded) {
        // (M6) احتياط محمي بقفل تزامن: WAL checkpoint(TRUNCATE) + التحقق الصارم من busy == 0
        await AppDatabase.runWithBackupCopyGuard(() async {
          var checkpointedCleanly = false;
          for (var attempt = 0; attempt < 3; attempt++) {
            try {
              final cpRows = await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
              if (cpRows.isNotEmpty) {
                final busyVal =
                    (cpRows.first['busy'] as num?)?.toInt() ??
                    (cpRows.first.values.first as num?)?.toInt() ??
                    1;
                if (busyVal == 0) {
                  checkpointedCleanly = true;
                  break;
                }
              }
            } catch (_) {}
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          if (!checkpointedCleanly) {
            throw const BackupRestoreException(
              'تعذّر إتمام WAL checkpoint قبل نسخ قاعدة البيانات لوجود قفل كتابة نشط.',
            );
          }
          final srcPath = db.path;
          if (srcPath.isNotEmpty &&
              srcPath != ':memory:' &&
              !srcPath.contains('in_memory') &&
              await File(srcPath).exists()) {
            await File(srcPath).copy(vacuumDbPath);
          } else {
            throw const BackupRestoreException(
              'تعذّر استخراج ملف قاعدة البيانات عبر VACUUM INTO.',
            );
          }
        });
      }

      final dbBytes = await vacuumDbFile.readAsBytes();

      // 2) جمع الصور والمرفقات المرجعية لحزمها داخل media/ في أرشيف .nexora (M4)
      await MediaPaths.ensureDocsDir();
      final mediaEntries = <ArchiveFile>[];
      final mediaManifestMap = <String, Map<String, String>>{};
      final seenStoredPaths = <String>{};
      var mediaIdx = 0;

      Future<void> collectMediaFile(Object? rawVal) async {
        final stored = '${rawVal ?? ''}'.trim();
        if (stored.isEmpty || !seenStoredPaths.add(stored)) return;
        try {
          final abs = MediaPaths.toAbsolute(stored);
          final f = File(abs);
          if (!await f.exists()) return;
          final len = await f.length();
          if (len <= 0 || len > 25 * 1024 * 1024) return;
          final bytes = await f.readAsBytes();
          if (bytes.isEmpty) return;
          final hash = sha256.convert(bytes).toString();
          var rel = MediaPaths.toRelative(stored).replaceAll('\\', '/');
          // تنظيف المسار ومنع الخروج عبر .. أو المسارات المطلقة داخل الأرشيف
          if (rel.startsWith('/') ||
              RegExp(r'^[A-Za-z]:').hasMatch(rel) ||
              rel.split('/').contains('..')) {
            final baseName = p.basename(stored).replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
            rel = 'restored_media/${mediaIdx++}_$baseName';
          }
          while (mediaManifestMap.containsKey('media/$rel')) {
            rel = 'restored_media/${mediaIdx++}_${p.basename(rel)}';
          }
          final archivePath = 'media/$rel';
          mediaEntries.add(ArchiveFile(archivePath, bytes.length, bytes));
          mediaManifestMap[archivePath] = <String, String>{
            'storedPath': stored,
            'relativePath': rel,
            'sha256': hash,
          };
        } catch (_) {}
      }

      Future<void> collectFromQuery(String sql) async {
        try {
          final rows = await db.rawQuery(sql);
          for (final r in rows) {
            for (final v in r.values) {
              await collectMediaFile(v);
            }
          }
        } catch (_) {}
      }

      await collectFromQuery(
        "SELECT attachment, image FROM transactions WHERE COALESCE(attachment,'') != '' OR COALESCE(image,'') != ''",
      );
      await collectFromQuery(
        "SELECT image FROM accounts WHERE COALESCE(image,'') != ''",
      );
      await collectFromQuery(
        "SELECT image FROM items WHERE COALESCE(image,'') != ''",
      );
      await collectFromQuery(
        "SELECT image_path FROM item_categories WHERE COALESCE(image_path,'') != ''",
      );
      await collectFromQuery(
        "SELECT media_path FROM messages WHERE COALESCE(media_path,'') != ''",
      );
      await collectFromQuery(
        "SELECT value FROM settings WHERE key = 'logo' AND COALESCE(value,'') != ''",
      );

      // 3) بناء ملف manifest.json بالمواصفات المعمارية المطلوبة
      final manifest = BackupManifest(
        app: 'Nexora',
        version: kAppVersion,
        workspaceId: workspaceId,
        createdAt: nowUtc.toIso8601String(),
        schemaVersion: AppDatabase.schemaVersion,
        lastTransactionTime: lastTx?.toUtc().toIso8601String() ?? '',
        mediaFiles: mediaManifestMap,
      );
      final manifestJsonStr =
          const JsonEncoder.withIndent('  ').convert(manifest.toJson());
      final manifestBytes = utf8.encode(manifestJsonStr);

      // 4) حزم الملفات في أرشيف مضغوط بصيغة Gzip
      final archive = Archive()
        ..addFile(
          ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
        )
        ..addFile(
          ArchiveFile('database.db', dbBytes.length, dbBytes),
        );
      for (final mf in mediaEntries) {
        archive.addFile(mf);
      }

      final tarBytes = TarEncoder().encode(archive);
      final gzBytes = const GZipEncoder().encode(tarBytes);

      final File outFile;
      if (targetFile != null) {
        outFile = targetFile;
      } else {
        Directory outDir;
        if (outputDirectory != null) {
          outDir = outputDirectory;
        } else {
          try {
            outDir = await getTemporaryDirectory();
          } catch (_) {
            outDir = Directory.systemTemp;
          }
        }
        final fileName = customFileName ??
            formatBackupFileName(auto: effectiveAuto, forFileSystem: true);
        outFile = File(p.join(outDir.path, fileName));
      }

      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(gzBytes, flush: true);
      return outFile;
    } finally {
      try {
        if (await tempWorkDir.exists()) {
          await tempWorkDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  /// يفحص ما إذا كانت المنشأة المحلية فارغة/جديدة تماماً (للسماح باستعادة نسخة المالك على هاتف جديد).
  static Future<bool> _isLocalWorkspaceFreshOrEmpty(
    Repo repo,
    DateTime? localLastTx,
  ) async {
    if (localLastTx != null) return false;
    try {
      final db = await repo.database;
      final accCount = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM accounts WHERE COALESCE(deleted_at, '') = ''",
      );
      if (((accCount.first['c'] as num?)?.toInt() ?? 0) > 0) return false;
      final itemCount = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM items WHERE COALESCE(deleted_at, '') = '' AND COALESCE(is_deleted, 0) = 0",
      );
      if (((itemCount.first['c'] as num?)?.toInt() ?? 0) > 0) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// إنشاء لقطة الأمان التلقائية الصامتة قبل الاستعادة باسم:
  /// `Safety_Snapshot_Before_Restore.nexora` مع تنفيذ `PRAGMA wal_checkpoint(TRUNCATE)`
  /// والاحتفاظ بآخر لقطتي أمان لمنع الكتابة الفورية فوق اللقطة السليمة عند تكرار المحاولة.
  static Future<File> createSafetySnapshotBeforeRestore(
    Repo repo, {
    Directory? targetDir,
  }) async {
    try {
      final db = await repo.database;
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}

    final dir = targetDir ?? await backupsDirectory();
    await dir.create(recursive: true);
    final snapshotFile =
        File(p.join(dir.path, '$kSafetySnapshotBaseName.nexora'));

    if (await snapshotFile.exists()) {
      try {
        final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
        final rotatedFile = File(
          p.join(dir.path, '${kSafetySnapshotBaseName}_$ts.nexora'),
        );
        await snapshotFile.copy(rotatedFile.path);

        // الاحتفاظ بآخر لقطتي أمان مؤرختين بجانب اللقطة الأساسية الحالية
        final historical = <File>[];
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('${kSafetySnapshotBaseName}_') &&
              name.endsWith('.nexora')) {
            historical.add(entity);
          }
        }
        if (historical.length > 2) {
          historical.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
          for (final old in historical.skip(2)) {
            try {
              await old.delete();
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    return createNexoraPackage(
      repo,
      targetFile: snapshotFile,
      isSafetySnapshot: true,
    );
  }

  /// 4. فك ضغط الأرشيف مؤقتاً وقراءة `manifest.json` والتحقق من هوية المنشأة
  /// ومقارنة تاريخ أحدث حركة في النسخة مع تاريخ أحدث حركة في القاعدة المحلية.
  static Future<BackupInspectionResult> inspectBackupBytes(
    Repo repo,
    List<int> rawBytes, {
    SyncEngine? engine,
    SubscriptionState? sub,
    bool enforceSyncGuard = true,
    bool allowCrossWorkspace = false,
  }) async {
    if (!await canAccessBackupAndRestore(repo)) {
      throw const BackupRestoreException(
        'عمليات الاستيراد والاستعادة متاحة حصراً لمدير المنشأة أو الحساب الفردي.',
      );
    }
    if (enforceSyncGuard &&
        await isLiveCloudSyncActive(repo, engine: engine, sub: sub)) {
      throw const BackupRestoreException(kActiveSyncRestoreBlockedMessage);
    }
    if (rawBytes.isEmpty) {
      throw const BackupRestoreException('ملف النسخة الاحتياطية فارغ.');
    }

    final currentWorkspaceId = await repo.activeWorkspaceId();
    final localActivity = await repo.latestActivityInfo();
    final localLastTx = localActivity.latest;
    final isFreshLocal =
        allowCrossWorkspace || await _isLocalWorkspaceFreshOrEmpty(repo, localLastTx);

    // التحقق مما إذا كان الملف بصيغة Gzip (.nexora المحمية) أو JSON قديم
    final isGzip =
        rawBytes.length >= 2 && rawBytes[0] == 0x1f && rawBytes[1] == 0x8b;

    if (isGzip) {
      final tempExtractDir =
          await Directory.systemTemp.createTemp('nexora_pkg_inspect_');
      try {
        final decompressed = const GZipDecoder().decodeBytes(rawBytes);
        final archive = TarDecoder().decodeBytes(decompressed);

        ArchiveFile? manifestEntry;
        ArchiveFile? dbEntry;
        final mediaArchiveEntries = <ArchiveFile>[];
        for (final entry in archive.files) {
          if (!entry.isFile) continue;
          final normName = entry.name.replaceAll('\\', '/');
          final base = p.basename(normName);
          if (base == 'manifest.json' && !normName.startsWith('media/')) {
            manifestEntry = entry;
          } else if (base == 'database.db' && !normName.startsWith('media/')) {
            dbEntry = entry;
          } else if (normName.startsWith('media/')) {
            mediaArchiveEntries.add(entry);
          }
        }

        if (manifestEntry == null) {
          throw const BackupRestoreException(
            'حزمة .nexora تالفة: ملف manifest.json مفقود داخل الأرشيف.',
          );
        }
        if (dbEntry == null) {
          throw const BackupRestoreException(
            'حزمة .nexora تالفة: ملف database.db مفقود داخل الأرشيف.',
          );
        }

        final manifestText =
            utf8.decode(manifestEntry.content as List<int>).trim();
        final decodedManifest = jsonDecode(manifestText);
        if (decodedManifest is! Map) {
          throw const BackupRestoreException('بنية manifest.json غير صالحة.');
        }
        final manifest = BackupManifest.fromJson(
          Map<String, dynamic>.from(decodedManifest),
        );

        // التحقق من هوية المنشأة (workspace_id) مع السماح بالاستعادة على هاتف جديد فارغ أو عند تفعيل allowCrossWorkspace
        if (!isFreshLocal &&
            manifest.workspaceId.isNotEmpty &&
            currentWorkspaceId.isNotEmpty &&
            currentWorkspaceId != 'default' &&
            manifest.workspaceId != currentWorkspaceId) {
          throw BackupWorkspaceMismatchException(
            backupWorkspaceId: manifest.workspaceId,
            currentWorkspaceId: currentWorkspaceId,
          );
        }

        final extractedDbFile = File(p.join(tempExtractDir.path, 'database.db'));
        final dbContent = dbEntry.content as List<int>;
        if (!_hasValidSqliteHeader(dbContent)) {
          throw const BackupRestoreException(
            'ملف قاعدة البيانات داخل الحزمة تالف أو ليس بصيغة SQLite 3 صالحة.',
          );
        }
        await extractedDbFile.writeAsBytes(dbContent, flush: true);

        // استخراج ملفات المرفقات/الصور مع التحقق من سلامة المسار والبصمة (M4)
        Directory? extractedMediaDir;
        if (mediaArchiveEntries.isNotEmpty) {
          extractedMediaDir = Directory(p.join(tempExtractDir.path, 'media'));
          await extractedMediaDir.create(recursive: true);
          for (final entry in mediaArchiveEntries) {
            final normName = entry.name.replaceAll('\\', '/');
            final relFromMedia = normName.substring('media/'.length);
            if (relFromMedia.isEmpty ||
                relFromMedia.startsWith('/') ||
                relFromMedia.split('/').contains('..')) {
              throw BackupRestoreException(
                'مسار مرفق غير آمن داخل الحزمة: $normName',
              );
            }
            final contentBytes = entry.content as List<int>;
            final meta = manifest.mediaFiles[normName];
            final expectedSha = meta?['sha256'] ?? '';
            if (expectedSha.isNotEmpty) {
              final actualSha = sha256.convert(contentBytes).toString();
              if (actualSha != expectedSha) {
                throw BackupRestoreException(
                  'تلف في مرفق النسخة الاحتياطية ($normName): عدم تطابق التجزئة.',
                );
              }
            }
            final destFile = File(p.join(extractedMediaDir.path, relFromMedia));
            await destFile.parent.create(recursive: true);
            await destFile.writeAsBytes(contentBytes, flush: true);
          }
        }

        // فحص سلامة قاعدة البيانات المستخرجة + فحص المفاتيح الأجنبية (M7) + قراءة أحدث نشاط (M8)
        DateTime? embeddedDbLatestTx;
        var embeddedDateReadFailed = false;
        Database? inspectDb;
        try {
          inspectDb = await databaseFactory.openDatabase(
            extractedDbFile.path,
            options: OpenDatabaseOptions(readOnly: true),
          );
          final checkRows = await inspectDb.rawQuery('PRAGMA quick_check');
          if (checkRows.isNotEmpty) {
            final status = '${checkRows.first.values.first ?? ''}'.trim().toLowerCase();
            if (status.isNotEmpty && status != 'ok') {
              throw BackupRestoreException(
                'ملف قاعدة البيانات داخل الحزمة تالف (فشل فحص السلامة: $status).',
              );
            }
          }
          // (M7) فحص المفاتيح الأجنبية داخل الحزمة لمنع استعادة قواعد تالفة العلاقات
          final fkRows = await inspectDb.rawQuery('PRAGMA foreign_key_check');
          if (fkRows.isNotEmpty) {
            throw BackupRestoreException(
              'ملف قاعدة البيانات داخل الحزمة يحتوي علاقات معطوبة (${fkRows.length} خلل في المفاتيح الأجنبية).',
            );
          }
          final embeddedActivity =
              await Repo.latestActivityInfoFromDb(inspectDb);
          embeddedDbLatestTx = embeddedActivity.latest;
          embeddedDateReadFailed = embeddedActivity.readFailed;
        } catch (e) {
          if (e is BackupRestoreException) rethrow;
          throw BackupRestoreException(
            'ملف قاعدة البيانات داخل الحزمة غير صالح للقراءة: $e',
          );
        } finally {
          if (inspectDb != null && inspectDb.isOpen) {
            try {
              await inspectDb.close();
            } catch (_) {}
          }
        }

        final effectiveTxDate =
            embeddedDbLatestTx != null && manifest.lastTransactionDate != null
                ? (embeddedDbLatestTx.isAfter(manifest.lastTransactionDate!)
                    ? embeddedDbLatestTx
                    : manifest.lastTransactionDate)
                : (embeddedDbLatestTx ?? manifest.lastTransactionDate);
        final backupCompareTime = effectiveTxDate ?? manifest.createdAtDate;
        final isOutdated = _isBackupOlder(
          backupTime: backupCompareTime,
          localLastTxTime: localLastTx,
          backupHasTx: effectiveTxDate != null,
        );

        return BackupInspectionResult(
          manifest: manifest,
          extractedDbFile: extractedDbFile,
          extractedMediaDir: extractedMediaDir,
          tempDir: tempExtractDir,
          localLastTransactionTime: localLastTx,
          backupComparisonTime: backupCompareTime,
          isOutdated: isOutdated,
          dateReadFailed: localActivity.readFailed || embeddedDateReadFailed,
        );
      } catch (e) {
        try {
          if (await tempExtractDir.exists()) {
            await tempExtractDir.delete(recursive: true);
          }
        } catch (_) {}
        if (e is BackupRestoreException) rethrow;
        throw BackupRestoreException('تعذّر قراءة حزمة النسخة الاحتياطية: $e');
      }
    }

    // التوافق الخلفي مع ملفات JSON القديمة إن وجدت
    try {
      var text = utf8.decode(rawBytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const BackupRestoreException('ملف النسخة الاحتياطية غير صالح.');
      }
      final map = Map<String, Object?>.from(decoded);
      final wsId =
          '${map['workspace_id'] ?? map['workspaceId'] ?? currentWorkspaceId}'
              .trim();
      if (!isFreshLocal &&
          wsId.isNotEmpty &&
          currentWorkspaceId.isNotEmpty &&
          currentWorkspaceId != 'default' &&
          map.containsKey('workspace_id') &&
          wsId != currentWorkspaceId) {
        throw BackupWorkspaceMismatchException(
          backupWorkspaceId: wsId,
          currentWorkspaceId: currentWorkspaceId,
        );
      }

      DateTime? backupLatestTx;
      final dataMap = map['data'];
      if (dataMap is Map && dataMap['transactions'] is List) {
        for (final row in (dataMap['transactions'] as List)) {
          if (row is Map) {
            if ('${row['deleted_at'] ?? ''}'.trim().isNotEmpty) continue;
            for (final k in ['updated_at', 'created_at', 'date']) {
              final dt = DateTime.tryParse('${row[k] ?? ''}'.trim());
              if (dt != null &&
                  (backupLatestTx == null || dt.isAfter(backupLatestTx))) {
                backupLatestTx = dt;
              }
            }
          }
        }
      }

      final createdAtStr =
          '${map['created_at'] ?? DateTime.now().toUtc().toIso8601String()}'
              .trim();
      final manifest = BackupManifest(
        app: 'Nexora',
        version: '${map['version'] ?? kAppVersion}',
        workspaceId: wsId,
        createdAt: createdAtStr,
        schemaVersion:
            (map['schema_version'] as num?)?.toInt() ??
            (map['db_version'] as num?)?.toInt() ??
            AppDatabase.schemaVersion,
        lastTransactionTime: backupLatestTx?.toUtc().toIso8601String() ??
            '${map['last_transaction_time'] ?? ''}',
      );

      final compareTime = manifest.effectiveComparisonDate;
      final isOutdated = _isBackupOlder(
        backupTime: compareTime,
        localLastTxTime: localLastTx,
        backupHasTx: manifest.lastTransactionDate != null,
      );

      return BackupInspectionResult(
        manifest: manifest,
        legacyJsonPayload: map,
        localLastTransactionTime: localLastTx,
        backupComparisonTime: compareTime,
        isOutdated: isOutdated,
      );
    } catch (e) {
      if (e is BackupRestoreException) rethrow;
      throw BackupRestoreException('ملف النسخة الاحتياطية غير صالح: $e');
    }
  }

  /// فحص ملف نسخة احتياطية من القرص مباشرة.
  static Future<BackupInspectionResult> inspectBackupFile(
    Repo repo,
    File file, {
    SyncEngine? engine,
    SubscriptionState? sub,
    bool enforceSyncGuard = true,
    bool allowCrossWorkspace = false,
  }) async {
    if (!await file.exists()) {
      throw const BackupRestoreException('ملف النسخة الاحتياطية غير موجود.');
    }
    final bytes = await file.readAsBytes();
    return inspectBackupBytes(
      repo,
      bytes,
      engine: engine,
      sub: sub,
      enforceSyncGuard: enforceSyncGuard,
      allowCrossWorkspace: allowCrossWorkspace,
    );
  }

  /// فحص ملف الحزمة `.nexora` (صيغة مساعدة متوافقة مع واجهة الاستعادة والاختبارات).
  static Future<BackupInspectionResult> inspectPackage(
    File file,
    Repo repo, {
    SyncEngine? syncEngine,
    SubscriptionState? sub,
    bool enforceSyncGuard = true,
    bool allowCrossWorkspace = false,
  }) =>
      inspectBackupFile(
        repo,
        file,
        engine: syncEngine,
        sub: sub,
        enforceSyncGuard: enforceSyncGuard,
        allowCrossWorkspace: allowCrossWorkspace,
      );

  static bool _isBackupOlder({
    required DateTime? backupTime,
    required DateTime? localLastTxTime,
    required bool backupHasTx,
  }) {
    if (localLastTxTime == null) return false;
    if (!backupHasTx && backupTime == null) return true;
    if (backupTime == null) return false;
    return backupTime.toUtc().isBefore(localLastTxTime.toUtc());
  }

  /// تنفيذ الاستعادة من نتيجة الفحص مع دعم كتابة التأكيد الصريح ومجلد لقطة الأمان.
  static Future<BackupRestoreResult> restoreFromInspection({
    required BackupInspectionResult inspection,
    required Repo repo,
    SyncEngine? syncEngine,
    SubscriptionState? sub,
    String? explicitConfirmationText,
    Directory? safetySnapshotDirectory,
    bool allowCrossWorkspace = false,
    bool enforceSyncGuard = true,
  }) {
    final trimmed = explicitConfirmationText?.trim() ?? '';
    final isConfirmed = trimmed == 'استعادة' ||
        trimmed == 'موافق' ||
        trimmed.toUpperCase() == 'RESTORE' ||
        trimmed.toUpperCase() == 'CONFIRM';
    return executeRestore(
      repo,
      inspection,
      engine: syncEngine,
      sub: sub,
      confirmedOutdated: isConfirmed,
      safetySnapshotDirectory: safetySnapshotDirectory,
      allowCrossWorkspace: allowCrossWorkspace,
      enforceSyncGuard: enforceSyncGuard,
    );
  }

  /// 5. تنفيذ الاستعادة الكاملة بأمان:
  /// - التحقق من الصلاحيات وعدم وجود مزامنة نشطة.
  /// - التحقق من تأكيد المدير إذا كانت النسخة أقدم من البيانات الحالية.
  /// - أخذ لقطة الأمان الصامتة `Safety_Snapshot_Before_Restore` قبل الاستبدال.
  /// - استبدال ملف قاعدة البيانات، إعادة فتح الاتصال، وتحديث حالة المستودع.
  static Future<BackupRestoreResult> executeRestore(
    Repo repo,
    BackupInspectionResult inspection, {
    SyncEngine? engine,
    SubscriptionState? sub,
    bool confirmedOutdated = false,
    Directory? safetySnapshotDirectory,
    bool allowCrossWorkspace = false,
    bool enforceSyncGuard = true,
  }) async {
    if (!await canAccessBackupAndRestore(repo)) {
      throw const BackupRestoreException(
        'عمليات الاستيراد والاستعادة متاحة حصراً لمدير المنشأة أو الحساب الفردي.',
      );
    }
    if (enforceSyncGuard &&
        await isLiveCloudSyncActive(repo, engine: engine, sub: sub)) {
      throw const BackupRestoreException(kActiveSyncRestoreBlockedMessage);
    }

    final liveActivity = await repo.latestActivityInfo();
    final liveLocalLastTx =
        liveActivity.latest ?? inspection.localLastTransactionTime;
    final dateReadFailed = inspection.dateReadFailed || liveActivity.readFailed;
    final isFreshLocal =
        allowCrossWorkspace || await _isLocalWorkspaceFreshOrEmpty(repo, liveLocalLastTx);

    if (!isFreshLocal) {
      final currentWorkspaceId = await repo.activeWorkspaceId();
      final backupWsId = inspection.manifest.workspaceId.trim();
      if (backupWsId.isNotEmpty &&
          currentWorkspaceId.isNotEmpty &&
          currentWorkspaceId != 'default' &&
          backupWsId != currentWorkspaceId) {
        throw BackupWorkspaceMismatchException(
          backupWorkspaceId: backupWsId,
          currentWorkspaceId: currentWorkspaceId,
        );
      }
    }
    final backupCompareTime =
        inspection.backupComparisonTime ?? inspection.manifest.effectiveComparisonDate;
    final isCurrentlyOutdated = inspection.isOutdated ||
        _isBackupOlder(
          backupTime: backupCompareTime,
          localLastTxTime: liveLocalLastTx,
          backupHasTx: inspection.manifest.lastTransactionDate != null ||
              inspection.backupComparisonTime != null,
        );

    if ((isCurrentlyOutdated || (dateReadFailed && !isFreshLocal)) &&
        !confirmedOutdated) {
      throw BackupOutdatedConflictException(
        backupTime: backupCompareTime ?? DateTime.now(),
        currentLastTxTime: liveLocalLastTx ?? DateTime.now(),
      );
    }

    // 1) لقطة الأمان التلقائية الصامتة قبل الاستبدال مباشرة
    final File safetySnapshot = await createSafetySnapshotBeforeRestore(
      repo,
      targetDir: safetySnapshotDirectory,
    );

    final wasEngineStarted = engine?.hasStarted ?? false;
    try {
      engine?.stop();
    } catch (_) {}

    try {
      int restoredCount = 0;
      if (inspection.extractedDbFile != null) {
        final dbFile = inspection.extractedDbFile!;
        final reopenedDb = await repo.replaceDatabaseFile(
          dbFile,
          workspaceId: inspection.manifest.workspaceId,
        );

        // استعادة المرفقات والصور من الأرشيف إلى مجلد المستندات وتحديث المسارات المطلقة إن وُجدت (M4)
        final mediaDir = inspection.extractedMediaDir;
        if (mediaDir != null && await mediaDir.exists()) {
          String? docsPath;
          try {
            docsPath = await MediaPaths.ensureDocsDir();
            docsPath ??= (await getApplicationDocumentsDirectory()).path;
          } catch (_) {
            docsPath = null;
          }
          if (docsPath != null && docsPath.isNotEmpty) {
            final pathRemaps = <String, String>{};
            if (inspection.manifest.mediaFiles.isNotEmpty) {
              for (final entry in inspection.manifest.mediaFiles.entries) {
                final archiveKey = entry.key;
                final relFromMedia = archiveKey.startsWith('media/')
                    ? archiveKey.substring('media/'.length)
                    : (entry.value['relativePath'] ?? '');
                final targetRel = (entry.value['relativePath'] ?? relFromMedia)
                    .replaceAll('\\', '/');
                if (relFromMedia.isEmpty ||
                    targetRel.isEmpty ||
                    targetRel.split('/').contains('..')) {
                  continue;
                }
                final srcMediaFile = File(p.join(mediaDir.path, relFromMedia));
                if (!await srcMediaFile.exists()) continue;
                final dstMediaFile = File(p.join(docsPath, targetRel));
                await dstMediaFile.parent.create(recursive: true);
                await srcMediaFile.copy(dstMediaFile.path);
                final origStored = entry.value['storedPath'] ?? '';
                if (origStored.isNotEmpty && origStored != targetRel) {
                  pathRemaps[origStored] = targetRel;
                }
              }
            } else {
              await for (final ent in mediaDir.list(recursive: true)) {
                if (ent is! File) continue;
                final rel = p.relative(ent.path, from: mediaDir.path);
                final dst = File(p.join(docsPath, rel));
                await dst.parent.create(recursive: true);
                await ent.copy(dst.path);
              }
            }
            if (pathRemaps.isNotEmpty) {
              for (final entry in pathRemaps.entries) {
                final oldPath = entry.key;
                final newRel = entry.value;
                try {
                  await reopenedDb.update('transactions', {'attachment': newRel},
                      where: 'attachment = ?', whereArgs: [oldPath]);
                  await reopenedDb.update('transactions', {'image': newRel},
                      where: 'image = ?', whereArgs: [oldPath]);
                  await reopenedDb.update('accounts', {'image': newRel},
                      where: 'image = ?', whereArgs: [oldPath]);
                  await reopenedDb.update('items', {'image': newRel},
                      where: 'image = ?', whereArgs: [oldPath]);
                  await reopenedDb.update('item_categories', {'image_path': newRel},
                      where: 'image_path = ?', whereArgs: [oldPath]);
                  await reopenedDb.update('messages', {'media_path': newRel},
                      where: 'media_path = ?', whereArgs: [oldPath]);
                  await reopenedDb.update('settings', {'value': newRel},
                      where: "key = 'logo' AND value = ?", whereArgs: [oldPath]);
                } catch (_) {}
              }
            }
          }
        }

        // حساب إجمالي السجلات المستعادة لعرضها للمستخدم
        for (final table in [
          'accounts',
          'transactions',
          'vouchers',
          'items',
          'item_categories',
          'sections',
        ]) {
          try {
            final r =
                await reopenedDb.rawQuery('SELECT COUNT(*) AS c FROM $table');
            restoredCount += (r.first['c'] as num?)?.toInt() ?? 0;
          } catch (_) {}
        }
      } else if (inspection.legacyJsonPayload != null) {
        restoredCount = await repo.importAll(
          inspection.legacyJsonPayload!,
          allowCrossFingerprint: allowCrossWorkspace,
        );
      } else {
        throw const BackupRestoreException('لا توجد بيانات قابلة للاستعادة.');
      }

      return BackupRestoreResult(
        manifest: inspection.manifest,
        safetySnapshotFile: safetySnapshot,
        restoredRecordsCount: restoredCount,
      );
    } finally {
      if (wasEngineStarted && engine != null && !engine.hasStarted) {
        try {
          await engine.start();
        } catch (_) {}
      }
      await inspection.dispose();
    }
  }
}
