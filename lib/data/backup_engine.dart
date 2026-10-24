import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_version.dart';
import '../core/cloud_config.dart';
import '../core/database.dart';
import '../core/format.dart';
import 'repository.dart';
import 'sync/subscription_guard.dart';
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

  const BackupManifest({
    required this.app,
    required this.version,
    required this.workspaceId,
    required this.createdAt,
    required this.schemaVersion,
    required this.lastTransactionTime,
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
      };

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    final appVal = '${json['app'] ?? ''}'.trim();
    if (appVal.toLowerCase() != 'nexora') {
      throw const BackupRestoreException(
        'ملف manifest.json غير صالح أو لا ينتمي لتطبيق Nexora.',
      );
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
    );
  }
}

/// نتيجة فحص وفك ضغط حزمة `.nexora` مؤقتاً قبل الاستعادة.
class BackupInspectionResult {
  final BackupManifest manifest;
  final File? extractedDbFile;
  final Map<String, Object?>? legacyJsonPayload;
  final Directory? tempDir;
  final DateTime? localLastTransactionTime;
  final DateTime? backupComparisonTime;
  final bool isOutdated;

  const BackupInspectionResult({
    required this.manifest,
    this.extractedDbFile,
    this.legacyJsonPayload,
    this.tempDir,
    this.localLastTransactionTime,
    this.backupComparisonTime,
    required this.isOutdated,
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
    if (effectiveEngine != null && effectiveEngine.isCloudSyncActive) {
      final effectiveSub = sub ?? SubscriptionGuard.lastState;
      if (!effectiveSub.expired && !effectiveSub.isFrozen && effectiveSub.isActive) {
        return true;
      }
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
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return false;
      final effectiveSub = sub ?? SubscriptionGuard.lastState;
      if (effectiveSub.expired || effectiveSub.isFrozen) {
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
        // احتياط آمن إذا كان محرك SQLite على نظام قديم لا يدعم VACUUM INTO
        try {
          await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
        } catch (_) {}
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
      }

      final dbBytes = await vacuumDbFile.readAsBytes();

      // 2) بناء ملف manifest.json بالمواصفات المعمارية المطلوبة
      final manifest = BackupManifest(
        app: 'Nexora',
        version: kAppVersion,
        workspaceId: workspaceId,
        createdAt: nowUtc.toIso8601String(),
        schemaVersion: AppDatabase.schemaVersion,
        lastTransactionTime: lastTx?.toUtc().toIso8601String() ?? '',
      );
      final manifestJsonStr =
          const JsonEncoder.withIndent('  ').convert(manifest.toJson());
      final manifestBytes = utf8.encode(manifestJsonStr);

      // 3) حزم الملفين في أرشيف مضغوط بصيغة Gzip
      final archive = Archive()
        ..addFile(
          ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
        )
        ..addFile(
          ArchiveFile('database.db', dbBytes.length, dbBytes),
        );

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

  /// إنشاء لقطة الأمان التلقائية الصامتة قبل الاستعادة باسم:
  /// `Safety_Snapshot_Before_Restore.nexora`
  static Future<File> createSafetySnapshotBeforeRestore(
    Repo repo, {
    Directory? targetDir,
  }) async {
    final dir = targetDir ?? await backupsDirectory();
    final snapshotFile =
        File(p.join(dir.path, '$kSafetySnapshotBaseName.nexora'));
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
    final localLastTx = await repo.latestTransactionTime();

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
        for (final entry in archive.files) {
          final base = p.basename(entry.name);
          if (base == 'manifest.json') {
            manifestEntry = entry;
          } else if (base == 'database.db') {
            dbEntry = entry;
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

        // التحقق من هوية المنشأة (workspace_id)
        if (manifest.workspaceId.isNotEmpty &&
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
        if (dbContent.length < 16) {
          throw const BackupRestoreException(
            'ملف قاعدة البيانات داخل الحزمة تالف أو فارغ.',
          );
        }
        await extractedDbFile.writeAsBytes(dbContent, flush: true);

        final backupCompareTime = manifest.effectiveComparisonDate;
        final isOutdated = _isBackupOlder(
          backupTime: backupCompareTime,
          localLastTxTime: localLastTx,
          backupHasTx: manifest.lastTransactionDate != null,
        );

        return BackupInspectionResult(
          manifest: manifest,
          extractedDbFile: extractedDbFile,
          tempDir: tempExtractDir,
          localLastTransactionTime: localLastTx,
          backupComparisonTime: backupCompareTime,
          isOutdated: isOutdated,
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
      if (wsId.isNotEmpty &&
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
    );
  }

  /// فحص ملف الحزمة `.nexora` (صيغة مساعدة متوافقة مع واجهة الاستعادة والاختبارات).
  static Future<BackupInspectionResult> inspectPackage(
    File file,
    Repo repo, {
    SyncEngine? syncEngine,
    SubscriptionState? sub,
    bool enforceSyncGuard = true,
  }) =>
      inspectBackupFile(
        repo,
        file,
        engine: syncEngine,
        sub: sub,
        enforceSyncGuard: enforceSyncGuard,
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

    if (inspection.isOutdated && !confirmedOutdated) {
      throw BackupOutdatedConflictException(
        backupTime: inspection.backupComparisonTime ??
            inspection.manifest.effectiveComparisonDate ??
            DateTime.now(),
        currentLastTxTime:
            inspection.localLastTransactionTime ?? DateTime.now(),
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

      if (wasEngineStarted && engine != null) {
        try {
          await engine.start();
        } catch (_) {}
      }

      return BackupRestoreResult(
        manifest: inspection.manifest,
        safetySnapshotFile: safetySnapshot,
        restoredRecordsCount: restoredCount,
      );
    } finally {
      await inspection.dispose();
    }
  }
}
