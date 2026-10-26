import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../data/backup_engine.dart';
import '../data/google_drive_service.dart';
import '../data/providers.dart';
import '../data/sync/google_auth_service.dart';
import '../data/sync/sync_engine.dart';
import 'profile_dialog.dart';
import 'trial_ui.dart' show ensureFeatureUnlocked;
import 'widgets.dart';

/// النسخ الاحتياطي والاستعادة وسلة المهملات — محرك النسخ المحمي (.nexora).
class BackupScreen extends ConsumerStatefulWidget {
  /// عند true تُعرض بدون Scaffold خاص بها (لتُضمَّن داخل تبويب).
  final bool embedded;
  const BackupScreen({super.key, this.embedded = false});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  bool _cloudLoading = true;
  bool _liveSyncActive = false;
  String? _cloudError;
  GoogleAccountInfo? _googleAccount;
  GoogleDriveBackupInfo? _cloudBackup;

  /// بريد الحساب من الجلسة **الموحّدة** (قسم «حساب المؤسسة»).
  String? _accountEmail;

  final GoogleDriveService _drive = GoogleDriveService.instance;

  SyncEngine? _tryReadSyncEngine() {
    try {
      return ref.read(syncEngineProvider);
    } catch (_) {
      return null;
    }
  }

  SyncEngine? _tryWatchSyncEngine() {
    try {
      return ref.watch(syncEngineProvider);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadCloudState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshLiveSyncState();
  }

  Future<void> _refreshLiveSyncState() async {
    try {
      final repo = ref.read(repoProvider);
      final engine = _tryReadSyncEngine();
      final liveSync = await BackupEngine.isLiveCloudSyncActive(
        repo,
        syncEngine: engine,
      );
      if (mounted && _liveSyncActive != liveSync) {
        setState(() => _liveSyncActive = liveSync);
      }
    } catch (_) {}
  }

  Future<void> _loadCloudState() async {
    GoogleAccountInfo? account;
    GoogleDriveBackupInfo? backup;
    String? cloudError;
    bool liveSync = false;
    try {
      final repo = ref.read(repoProvider);
      final engine = _tryReadSyncEngine();
      liveSync = await BackupEngine.isLiveCloudSyncActive(
        repo,
        syncEngine: engine,
      );
      if (mounted && _liveSyncActive != liveSync) {
        setState(() => _liveSyncActive = liveSync);
      }
    } catch (_) {}
    try {
      account = await _drive.restoreSession();
      if (account != null) {
        try {
          backup = await _drive.latestBackup();
        } catch (e) {
          cloudError = '$e';
        }
      }
    } catch (e) {
      cloudError = '$e';
    }
    if (!mounted) return;
    String? accountEmail;
    try {
      final db = await ref.read(repoProvider).database;
      if (!mounted) return;
      accountEmail = (await GoogleAuthService(db).currentUserFromDb())?.email;
    } catch (_) {
      accountEmail = null;
    }
    if (!mounted) return;
    setState(() {
      _googleAccount = account;
      _cloudBackup = backup;
      _cloudError = cloudError;
      _accountEmail = accountEmail;
      _liveSyncActive = liveSync;
      _cloudLoading = false;
    });
  }

  /// إنشاء حزمة احتياطية مضغوطة محمية (.nexora) تحتوي على database.db (VACUUM INTO) و manifest.json.
  Future<File> _createBackupFile({bool auto = false}) async {
    final repo = ref.read(repoProvider);
    return BackupEngine.createNexoraPackage(repo, auto: auto);
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final file = await _createBackupFile();
      await Share.shareXFiles([
        XFile(file.path),
      ], subject: 'نسخة احتياطية — إدارة البيانات');
      if (mounted) {
        showSnack(
          context,
          'تم إنشاء النسخة الاحتياطية المحمية (.nexora) ✅',
        );
        await ref.read(repoProvider).notify(
              title: 'تم إنشاء نسخة احتياطية',
              body: 'اكتمل تصدير بياناتك بصيغة .nexora بنجاح',
              kind: 'success',
            );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر إنشاء النسخة: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// بعد استعادة المدير: تُجدول كل البيانات المستعادة كعمليات مزامنة
  /// فتصل رأساً إلى بقية أجهزة المجموعة (لا شيء يحدث خارج المجموعة).
  Future<void> _resyncGroupAfterRestore() async {
    try {
      final queued = await ref.read(repoProvider).resyncAllToGroup();
      if (queued > 0) {
        ref.read(syncEngineProvider).notifyNewOperation();
        if (mounted) {
          showSnack(
            context,
            'جارٍ مزامنة النسخة المستعادة إلى أجهزة المجموعة ($queued سجلًا) 🔄',
          );
        }
      }
    } catch (_) {}
  }

  Future<File> _materializePickedFile(PlatformFile picked) async {
    final path = picked.path;
    if (path != null && path.isNotEmpty) {
      final f = File(path);
      if (await f.exists()) return f;
    }
    Directory dir;
    try {
      dir = await getTemporaryDirectory();
    } catch (_) {
      dir = Directory.systemTemp;
    }
    final safeName = (picked.name.isNotEmpty ? picked.name : 'picked.nexora')
        .replaceAll(RegExp(r'[^\w\-. ]'), '_');
    final tempFile = File(
      p.join(
        dir.path,
        'nexora_picked_${DateTime.now().millisecondsSinceEpoch}_$safeName',
      ),
    );
    final bytes = picked.bytes;
    if (bytes != null) {
      await tempFile.writeAsBytes(bytes, flush: true);
      return tempFile;
    }
    final stream = picked.readStream;
    if (stream != null) {
      final all = <int>[];
      await for (final chunk in stream) {
        all.addAll(chunk);
      }
      await tempFile.writeAsBytes(all, flush: true);
      return tempFile;
    }
    throw const FormatException('لم يعُد مزوّد الملفات محتوى قابلًا للقراءة.');
  }

  /// فحص الملف واستعادته مع التحقق من التواريخ وأخذ لقطة الأمان التلقائية.
  Future<void> _inspectAndExecuteRestore(File archiveFile) async {
    final repo = ref.read(repoProvider);
    final syncEngine = _tryReadSyncEngine();

    // حظر الاستيراد أثناء المزامنة السحابية النشطة
    final isSyncing = (syncEngine?.isCloudSyncActive ?? false) ||
        await BackupEngine.isLiveCloudSyncActive(repo, syncEngine: syncEngine);
    if (isSyncing) {
      if (mounted) {
        showSnack(
          context,
          BackupEngine.syncActiveRestoreDisabledMessage,
          error: true,
        );
      }
      return;
    }

    // 1. فك ضغط الأرشيف مؤقتاً وقراءة manifest.json والتحقق من هوية المنشأة والتواريخ
    final inspection = await BackupEngine.inspectPackage(archiveFile, repo);
    try {
      String? explicitConfirmation;
      if (inspection.isOlderThanLocal) {
        if (!mounted) return;
        explicitConfirmation = await showOlderBackupConflictDialog(
          context,
          inspection: inspection,
        );
        if (explicitConfirmation == null) {
          return;
        }
      } else {
        if (!mounted) return;
        final ok = await confirmDialog(
          context,
          title: '⚠️ تأكيد استعادة النسخة الاحتياطية',
          message:
              'سيتم إنشاء لقطة أمان تلقائية لبياناتك الحالية باسم '
              '(${BackupEngine.safetySnapshotPrefix}) ثم استبدال قاعدة البيانات '
              'بمحتوى النسخة المختارة.\n\nهل تريد المتابعة؟',
          confirmText: 'استعادة الآن',
          danger: true,
        );
        if (!ok) return;
      }

      // 2. تنفيذ الاستعادة (يتضمن Pre-Restore Safety Snapshot + استبدال آمن + إعادة فتح القاعدة)
      final result = await BackupEngine.restoreFromInspection(
        inspection: inspection,
        repo: repo,
        syncEngine: syncEngine,
        explicitConfirmationText: explicitConfirmation,
        allowCrossWorkspace: false,
      );

      await _resyncGroupAfterRestore();
      // تحديث حالة التطبيق ومزودات Riverpod
      ref.invalidate(repoProvider);
      bump(ref);

      if (mounted) {
        showSnack(
          context,
          'تمت الاستعادة بنجاح ✅ (${result.restoredRecords} سجلًا) — حُفظت لقطة أمان احترازية.',
        );
      }
    } finally {
      await inspection.cleanup();
    }
  }

  Future<void> _restoreLocal() async {
    final repo = ref.read(repoProvider);
    final syncEngine = _tryReadSyncEngine();
    if ((syncEngine?.isCloudSyncActive ?? false) ||
        await BackupEngine.isLiveCloudSyncActive(repo, syncEngine: syncEngine)) {
      if (mounted) {
        showSnack(
          context,
          BackupEngine.syncActiveRestoreDisabledMessage,
          error: true,
        );
      }
      return;
    }

    setState(() => _busy = true);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (res == null) return;
      final file = await _materializePickedFile(res.files.single);
      await _inspectAndExecuteRestore(file);
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّرت الاستعادة: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<GoogleAccountInfo?> _ensureGoogleAccount() async {
    var account = _googleAccount ?? await _drive.restoreSession();
    if (account != null) {
      GoogleDriveBackupInfo? backup;
      String? cloudError;
      try {
        backup = await _drive.latestBackup();
      } catch (e) {
        cloudError = '$e';
      }
      if (mounted) {
        setState(() {
          _googleAccount = account;
          _cloudBackup = backup;
          _cloudError = cloudError;
        });
      }
    }
    return account;
  }

  Future<void> _uploadToGoogle() async {
    setState(() => _busy = true);
    try {
      final account = await _ensureGoogleAccount();
      if (account == null) {
        if (mounted) {
          showSnack(
            context,
            'سجّل الدخول من «الإعدادات ← حساب المؤسسة (Google)» أولاً',
            error: true,
          );
        }
        return;
      }
      final file = await _createBackupFile(auto: false);
      final backup = await _drive.uploadBackupFile(
        file,
        fileName: p.basename(file.path),
      );
      if (mounted) {
        setState(() {
          _cloudBackup = backup;
          _cloudError = null;
        });
        showSnack(context, 'تم رفع نسخة Google Drive (${backup.name}) ✅');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر رفع النسخة: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// فتح نافذة استعراض نسخ Google Drive المدمجة (Drive Backup Picker).
  Future<void> _openDriveBackupPicker() async {
    final repo = ref.read(repoProvider);
    final syncEngine = _tryReadSyncEngine();
    if ((syncEngine?.isCloudSyncActive ?? false) ||
        await BackupEngine.isLiveCloudSyncActive(repo, syncEngine: syncEngine)) {
      if (mounted) {
        showSnack(
          context,
          BackupEngine.syncActiveRestoreDisabledMessage,
          error: true,
        );
      }
      return;
    }

    final account = await _ensureGoogleAccount();
    if (account == null && _drive.debugListBackupsOverride == null) {
      if (mounted) {
        showSnack(
          context,
          'سجّل الدخول من «الإعدادات ← حساب المؤسسة (Google)» أولاً',
          error: true,
        );
      }
      return;
    }

    if (!mounted) return;
    final selectedFile = await showDriveBackupPickerDialog(
      context,
      driveService: _drive,
    );
    if (selectedFile == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await _inspectAndExecuteRestore(selectedFile);
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذّرت الاستعادة من Google Drive: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// يفتح نافذة الحساب الموحدة (المدخل الوحيد لتسجيل الدخول بـ Google في التطبيق).
  Future<void> _openAccountSection() async {
    await showAccountProfileDialog(context, ref);
    if (mounted) await _loadCloudState();
  }

  Future<void> _shareToDriveDirectly() async {
    setState(() => _busy = true);
    try {
      final file = await _createBackupFile();
      await Share.shareXFiles([
        XFile(file.path),
      ], subject: 'نسخة احتياطية سحابية — Google Drive');
      if (mounted) {
        showSnack(
          context,
          'تم تجهيز النسخة لمشاركتها وحفظها في Google Drive ☁️',
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر تصدير النسخة: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wsMode = ref.watch(workspaceModeProvider).valueOrNull ?? 'standalone';
    final wsOwner = ref.watch(isOwnerProvider).valueOrNull ?? true;
    final currentUser = ref.watch(currentUserProvider).valueOrNull;
    final deviceRole = ref.watch(deviceRoleProvider).valueOrNull?.role;
    final activeRole = currentUser?.role ?? deviceRole;

    final isEmployeeRole = activeRole == UserRole.cashier ||
        activeRole == UserRole.dataentry ||
        activeRole == UserRole.viewer ||
        activeRole == UserRole.accountant;

    final canAccessBackup = wsMode != 'member' &&
        !isEmployeeRole &&
        (wsMode == 'standalone' ||
            wsOwner ||
            activeRole == null ||
            activeRole == UserRole.admin ||
            activeRole == UserRole.agent);

    if (!canAccessBackup) {
      const restrictedBody = Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: EmptyState(
            icon: Icons.shield_outlined,
            title: 'النسخ والاستيراد مقيد',
            message:
                'عمليات النسخ الاحتياطي والاستعادة متاحة حصراً لحساب مدير المنشأة (Owner / Admin) والحساب الفردي، ومحجوبة عن واجهات الكاشير والموظفين.',
          ),
        ),
      );
      if (widget.embedded) return restrictedBody;
      return Scaffold(
        appBar: AppBar(title: const Text('النسخ الاحتياطي وإدارة البيانات')),
        body: restrictedBody,
      );
    }

    final counts = ref.watch(countsProvider).valueOrNull ?? {};
    final trash = ref.watch(trashProvider);
    final syncEngine = _tryWatchSyncEngine();
    final isSyncActive = (syncEngine?.isCloudSyncActive ?? false) || _liveSyncActive;
    final restoreDisabledBySync = isSyncActive;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
      children: [
        const SectionTitle('حالة البيانات'),
        StatCardGrid(
          children: [
            StatCard(
              title: 'الحسابات',
              value: '${counts['accounts'] ?? 0}',
              icon: Icons.people_alt_outlined,
              color: AppColors.primaryOf(context),
            ),
            StatCard(
              title: 'العمليات',
              value: '${counts['transactions'] ?? 0}',
              icon: Icons.receipt_long_outlined,
              color: AppColors.infoOf(context),
            ),
            StatCard(
              title: 'السندات',
              value: '${counts['vouchers'] ?? 0}',
              icon: Icons.receipt_outlined,
              color: AppColors.violetOf(context),
            ),
            StatCard(
              title: 'سلة المهملات',
              value: '${counts['trash'] ?? 0}',
              icon: Icons.delete_outline,
              color: AppColors.accentOf(context),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const SectionTitle('النسخ الاحتياطي (.nexora)'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'تُحفظ النسخة بصيغة مضغوطة محمية (.nexora) تضم قاعدة البيانات المدمجة '
                  'بالكامل (VACUUM INTO) وملف التعريف الوصفي (manifest.json)، مع أخذ لقطة '
                  'أمان تلقائية قبل أي استعادة.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: AppColors.text2Of(context),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _backup,
                        icon: const Icon(Icons.backup_outlined),
                        label: const Text('إنشاء نسخة'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: (_busy || restoreDisabledBySync)
                            ? null
                            : () async {
                                if (await ensureFeatureUnlocked(
                                  context,
                                  ref,
                                  featureKey: 'restore',
                                  featureName: 'نقاط الاسترجاع',
                                  description:
                                      'استرجع بياناتك من أي نسخة احتياطية أو ادمج قواعد البيانات بأمان.',
                                )) {
                                  await _restoreLocal();
                                }
                              },
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.restore_outlined, size: 18),
                            SizedBox(width: 8),
                            Text('استعادة'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (restoreDisabledBySync) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.sync_lock_rounded,
                          color: Color(0xFFB45309),
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            BackupEngine.syncActiveRestoreDisabledMessage,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF92400E),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const SectionTitle('النسخ السحابي عبر Google Drive'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'تُحفظ النسخ بصيغة (.nexora) داخل مساحة التطبيق في Google Drive، '
                  'ويمكنك استعراض النسخ المحفوظة والفلترة بينها أو مشاركتها واستعادتها مباشرة.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: AppColors.text2Of(context),
                  ),
                ),
                const SizedBox(height: 10),
                if (_cloudLoading)
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: SizedBox(
                      width: 24,
                      height: 24,
                      child: Icon(Icons.cloud_sync_outlined, size: 22),
                    ),
                    title: Text('جارٍ التحقق من حساب Google…'),
                  )
                else if (_accountEmail == null) ...[
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.manage_accounts_outlined),
                    title: Text('تسجيل الدخول بـ Google من مكانه الموحّد'),
                    subtitle: Text(
                      'مدخل التسجيل بـ Google واحد فقط في التطبيق: '
                      'الإعدادات ← «حساب المؤسسة (Google)». سجّل الدخول هناك '
                      'ليُربط حسابك بمساحة عملك، ثم عد لرفع النسخ واستعادتها.',
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _openAccountSection,
                      icon: const Icon(Icons.manage_accounts_outlined),
                      label: const Text('الانتقال إلى قسم الحساب'),
                    ),
                  ),
                ] else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      child: Text(
                        (_accountEmail!.isEmpty ? 'G' : _accountEmail![0])
                            .toUpperCase(),
                      ),
                    ),
                    title: const Text(
                      'حساب المؤسسة',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(_accountEmail!),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      Icons.cloud_done_outlined,
                      color: AppColors.primaryOf(context),
                    ),
                    title: Text(
                      _cloudBackup == null
                          ? 'لا توجد نسخة على Google Drive'
                          : 'آخر نسخة: ${_cloudBackup!.name}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    subtitle: _cloudBackup?.sizeLabel.isNotEmpty == true
                        ? Text(_cloudBackup!.sizeLabel)
                        : Text(
                            _googleAccount == null
                                ? 'سيُطلب منح صلاحية Drive عند أول رفع.'
                                : 'ستُنشأ النسخة عند أول رفع.',
                          ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy
                              ? null
                              : () async {
                                  if (await ensureFeatureUnlocked(
                                    context,
                                    ref,
                                    featureKey: 'cloud_backup',
                                    featureName:
                                        'النسخ السحابي عبر Google Drive',
                                    description:
                                        'نسخة احتياطية خاصة داخل Google Drive تُحدَّث بضغطة واحدة.',
                                  )) {
                                    await _uploadToGoogle();
                                  }
                                },
                          icon: const Icon(Icons.cloud_upload_outlined),
                          label: const Text('رفع / تحديث'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: (_busy || restoreDisabledBySync)
                              ? null
                              : () async {
                                  if (await ensureFeatureUnlocked(
                                    context,
                                    ref,
                                    featureKey: 'restore',
                                    featureName: 'الاستعادة من Google Drive',
                                    description:
                                        'استرجع نسختك المحفوظة في Google Drive متى احتجتها.',
                                  )) {
                                    await _openDriveBackupPicker();
                                  }
                                },
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const Text('استعراض واستعادة'),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_cloudError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _cloudError!,
                    style: TextStyle(
                      color: AppColors.dangerOf(context),
                      fontSize: 11.5,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _shareToDriveDirectly,
                    icon: const Icon(Icons.drive_folder_upload_outlined),
                    label: const Text('رفع / حفظ في تطبيق Google Drive 📤'),
                  ),
                ),
                if (_busy) ...[
                  const SizedBox(height: 10),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const SectionTitle('استخدام البيانات على أكثر من هاتف'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.phonelink, color: AppColors.primaryOf(context)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'نقل الحساب بين الأجهزة',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'التطبيق يعمل بلا إنترنت وكل البيانات محفوظة داخل جهازك، '
                  'ولا يوجد خادم يزامن الأجهزة لحظيًا. للعمل على هاتف ثانٍ:\n\n'
                  '١) أنشئ نسخة احتياطية هنا.\n'
                  '٢) أرسل الملف إلى الهاتف الآخر (واتساب أو درايف أو كابل).\n'
                  '٣) في الهاتف الآخر: النسخ الاحتياطي ← استعادة، واختر الملف.\n\n'
                  'ملاحظة مهمة: الاستعادة تستبدل بيانات الجهاز الثاني بالكامل '
                  'مع حفظ لقطة أمان تلقائية للبيانات السابقة.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.75,
                    color: AppColors.text2Of(context),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        SectionTitle(
          'سلة المهملات',
          actionLabel: 'تفريغ',
          onAction: () async {
            final ok = await confirmDialog(
              context,
              title: 'تفريغ سلة المهملات',
              message: 'سيُحذف كل ما بداخلها نهائيًا.',
              danger: true,
            );
            if (ok) {
              await ref.read(repoProvider).emptyTrash();
              bump(ref);
            }
          },
        ),
        trash.when(
          loading: () => const SizedBox.shrink(),
          error: (e, _) => Text('$e'),
          data: (items) {
            if (items.isEmpty) {
              return const EmptyState(
                icon: Icons.delete_outline,
                title: 'السلة فارغة',
                message: 'كل ما تحذفه يُحفظ هنا مؤقتًا ويمكن استرجاعه.',
              );
            }
            return Column(
              children: items.map((t) {
                final created = DateTime.tryParse(
                  (t['created_at'] ?? '') as String? ?? '',
                );
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      Icons.restore_from_trash_outlined,
                      color: AppColors.accentOf(context),
                    ),
                    title: Text(
                      '${t['label'] ?? t['store']}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      created == null ? '' : Fmt.dateTime(created),
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        await ref
                            .read(repoProvider)
                            .restoreFromTrash(t['id'] as int);
                        bump(ref);
                        if (context.mounted) {
                          showSnack(context, 'تم الاسترجاع ✅');
                        }
                      },
                      child: const Text('استرجاع'),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

/// نافذة استعراض نسخ Google Drive المدمجة (Drive Backup Picker).
/// تعرض قائمة النسخ المطابقة لبادئة التطبيق مع شريط بحث علوي للفلترة اللحظية،
/// وحجم كل ملف، وأيقونة مشاركة سريعة، وإمكانية الضغط على أي نسخة لتنزيلها واستعادتها.
Future<File?> showDriveBackupPickerDialog(
  BuildContext context, {
  GoogleDriveService? driveService,
}) {
  return showDialog<File?>(
    context: context,
    builder: (_) => DriveBackupPickerDialog(
      driveService: driveService ?? GoogleDriveService.instance,
    ),
  );
}

class DriveBackupPickerDialog extends StatefulWidget {
  final GoogleDriveService driveService;
  const DriveBackupPickerDialog({
    super.key,
    required this.driveService,
  });

  @override
  State<DriveBackupPickerDialog> createState() =>
      _DriveBackupPickerDialogState();
}

class _DriveBackupPickerDialogState extends State<DriveBackupPickerDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<GoogleDriveBackupInfo> _allBackups = const [];
  bool _loading = true;
  String? _downloadingId;
  String? _sharingId;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBackups() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.driveService.listBackups();
      if (!mounted) return;
      setState(() {
        _allBackups = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<GoogleDriveBackupInfo> get _filteredBackups {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _allBackups;
    return _allBackups.where((b) {
      final nameMatch = b.name.toLowerCase().contains(q);
      final dateStr =
          b.modifiedTime != null ? Fmt.dateTime(b.modifiedTime!) : '';
      return nameMatch || dateStr.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _selectAndDownload(GoogleDriveBackupInfo item) async {
    if (_downloadingId != null || _sharingId != null) return;
    setState(() {
      _downloadingId = item.id.isNotEmpty ? item.id : item.name;
      _error = null;
    });
    try {
      Directory dir;
      if (Platform.environment.containsKey('FLUTTER_TEST') ||
          widget.driveService.debugDownloadBackupByIdOverride != null) {
        dir = Directory.systemTemp;
      } else {
        try {
          dir = await getTemporaryDirectory();
        } catch (_) {
          dir = Directory.systemTemp;
        }
      }
      final safeName = item.name.replaceAll(RegExp(r'[^\w\-. ]'), '_');
      final target = File(
        p.join(
          dir.path,
          'drive_${DateTime.now().millisecondsSinceEpoch}_$safeName',
        ),
      );
      if (item.id.isNotEmpty) {
        await widget.driveService.downloadBackupById(item.id, target);
      } else {
        await widget.driveService.downloadLatestTo(target);
      }
      if (!mounted) return;
      Navigator.of(context).pop(target);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadingId = null;
        _error = 'تعذّر تنزيل النسخة: $e';
      });
    }
  }

  Future<void> _shareBackup(GoogleDriveBackupInfo item) async {
    if (_downloadingId != null || _sharingId != null) return;
    setState(() {
      _sharingId = item.id.isNotEmpty ? item.id : item.name;
      _error = null;
    });
    try {
      Directory dir;
      try {
        dir = await getTemporaryDirectory();
      } catch (_) {
        dir = Directory.systemTemp;
      }
      final safeName = item.name.replaceAll(RegExp(r'[^\w\-. ]'), '_');
      final target = File(p.join(dir.path, safeName));
      if (item.id.isNotEmpty) {
        await widget.driveService.downloadBackupById(item.id, target);
      } else {
        await widget.driveService.downloadLatestTo(target);
      }
      await Share.shareXFiles(
        [XFile(target.path)],
        subject: 'نسخة احتياطية — ${item.name}',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'تعذّرت مشاركة النسخة: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _sharingId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredBackups;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.cloud_download_rounded,
                    color: AppColors.primaryOf(context),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'نسخ Google Drive الاحتياطية',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'تحديث القائمة',
                    onPressed: _loading ? null : _loadBackups,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // شريط بحث علوي للفلترة اللحظية بين النسخ
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'ابحث في النسخ بالاسم أو التاريخ…',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    color: AppColors.dangerOf(context),
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : filtered.isEmpty
                        ? EmptyState(
                            icon: Icons.cloud_off_outlined,
                            title: _query.isEmpty
                                ? 'لا توجد نسخ محفوظة'
                                : 'لا توجد نتائج مطابقة',
                            message: _query.isEmpty
                                ? 'لم يُعثر على نسخ احتياطية مطابقة لبادئة التطبيق على Google Drive.'
                                : 'جرّب البحث بكلمة أو تاريخ آخر.',
                          )
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (ctx, i) {
                              final item = filtered[i];
                              final keyId =
                                  item.id.isNotEmpty ? item.id : item.name;
                              final isDownloading = _downloadingId == keyId;
                              final isSharing = _sharingId == keyId;
                              return Card(
                                margin: EdgeInsets.zero,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(
                                    color: AppColors.borderOf(context),
                                  ),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () => _selectAndDownload(item),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 40,
                                          height: 40,
                                          decoration: BoxDecoration(
                                            color: AppColors.primaryOf(context)
                                                .withValues(alpha: 0.12),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: isDownloading
                                              ? const Padding(
                                                  padding: EdgeInsets.all(10),
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                )
                                              : Icon(
                                                  Icons.folder_zip_outlined,
                                                  color: AppColors.primaryOf(
                                                    context,
                                                  ),
                                                ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item.name,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Wrap(
                                                spacing: 10,
                                                runSpacing: 2,
                                                children: [
                                                  if (item.modifiedTime != null)
                                                    Text(
                                                      Fmt.dateTime(
                                                        item.modifiedTime!,
                                                      ),
                                                      style: TextStyle(
                                                        fontSize: 11.5,
                                                        color:
                                                            AppColors.text3Of(
                                                          context,
                                                        ),
                                                      ),
                                                    ),
                                                  if (item.sizeLabel.isNotEmpty)
                                                    Text(
                                                      item.sizeLabel,
                                                      style: TextStyle(
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color:
                                                            AppColors.primaryOf(
                                                          context,
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'مشاركة الملف',
                                          onPressed: isSharing
                                              ? null
                                              : () => _shareBackup(item),
                                          icon: isSharing
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                )
                                              : const Icon(
                                                  Icons.share_outlined,
                                                  size: 20,
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('إلغاء'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// نافذة التحذير المالي الحرج عند محاولة استعادة نسخة أقدم من البيانات المحلية الحالية.
/// تطلب كتابة تأكيد صريح من المدير للمتابعة.
Future<String?> showOlderBackupConflictDialog(
  BuildContext context, {
  required BackupInspectionResult inspection,
}) {
  return showDialog<String?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => OlderBackupConflictDialog(inspection: inspection),
  );
}

class OlderBackupConflictDialog extends StatefulWidget {
  final BackupInspectionResult inspection;
  const OlderBackupConflictDialog({
    super.key,
    required this.inspection,
  });

  @override
  State<OlderBackupConflictDialog> createState() =>
      _OlderBackupConflictDialogState();
}

class _OlderBackupConflictDialogState extends State<OlderBackupConflictDialog> {
  final TextEditingController _confirmCtrl = TextEditingController();
  String _typed = '';

  bool get _isConfirmed {
    final t = _typed.trim();
    return t == 'استعادة' || t == 'موافق' || t.toUpperCase() == 'RESTORE';
  }

  @override
  void dispose() {
    _confirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final warningText = widget.inspection.criticalWarningMessage;
    return AlertDialog(
      backgroundColor: const Color(0xFFFEF2F2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFDC2626), width: 1.8),
      ),
      icon: const Icon(
        Icons.warning_amber_rounded,
        color: Color(0xFFDC2626),
        size: 44,
      ),
      title: const Text(
        'تحذير مالي حرج',
        style: TextStyle(
          color: Color(0xFF991B1B),
          fontWeight: FontWeight.w900,
          fontSize: 18,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF87171)),
              ),
              child: Text(
                warningText,
                style: const TextStyle(
                  color: Color(0xFF7F1D1D),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'لتأكيد المتابعة على مسؤوليتك، اكتب كلمة «استعادة» في الحقل أدناه '
              '(سيتم حفظ لقطة أمان تلقائية لبياناتك الحالية قبل الاستبدال):',
              style: TextStyle(
                color: Color(0xFF7F1D1D),
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmCtrl,
              onChanged: (v) => setState(() => _typed = v),
              decoration: InputDecoration(
                hintText: 'اكتب: استعادة',
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFDC2626),
          ),
          onPressed: _isConfirmed
              ? () => Navigator.of(context).pop(_typed.trim())
              : null,
          child: const Text('تأكيد الاستعادة'),
        ),
      ],
    );
  }
}

/// سجل النشاط — نقل شاشة `activity.js`.
class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acts = ref.watch(activityProvider);

    return acts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'تعذّر تحميل السجل',
        message: '$e',
      ),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            icon: Icons.history,
            title: 'لا نشاط بعد',
            message: 'كل إضافة أو تعديل أو حذف سيظهر هنا.',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 96),
          children: [
            SectionTitle(
              'آخر التغييرات',
              actionLabel: 'مسح السجل',
              onAction: () async {
                final ok = await confirmDialog(
                  context,
                  title: 'مسح سجل النشاط',
                  message: 'سيُمسح السجل بالكامل.',
                  danger: true,
                );
                if (ok) {
                  await ref.read(repoProvider).clearActivity();
                  bump(ref);
                }
              },
            ),
            for (final a in items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => showActivityDetails(context, ref, a),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: AppColors.primaryOf(context),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${a['text']}',
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${a['user_name'] ?? ''}',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.text3Of(context),
                              ),
                            ),
                            Text(
                              Fmt.relative(
                                DateTime.tryParse(
                                      (a['created_at'] ?? '') as String,
                                    ) ??
                                    DateTime.now(),
                              ),
                              style: TextStyle(
                                fontSize: 10.5,
                                color: AppColors.text3Of(context),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.chevron_left,
                          size: 18,
                          color: AppColors.text3Of(context),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// نافذة تفاصيل نشاط واحد: النص الكامل، النوع، المنفّذ، الوقت الدقيق،
/// وبيانات السجل المرتبط إن كان ما يزال موجوداً.
Future<void> showActivityDetails(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> a,
) async {
  final refType = '${a['ref_type'] ?? ''}';
  final refId = '${a['ref_id'] ?? ''}';
  final created = DateTime.tryParse('${a['created_at'] ?? ''}');

  final table = switch (refType) {
    'account' => 'accounts',
    'tx' => 'transactions',
    'voucher' => 'vouchers',
    'item' => 'items',
    'item_category' => 'item_categories',
    'user' => 'users',
    'stock' => 'stock_moves',
    _ => null,
  };
  final typeLabel = switch (refType) {
    'account' => 'حساب',
    'tx' => 'عملية حسابية',
    'voucher' => 'سند',
    'item' => 'صنف',
    'item_category' => 'فئة أصناف',
    'user' => 'مستخدم',
    'stock' => 'حركة مخزون',
    'trash' => 'سلة المهملات',
    _ => refType.isEmpty ? '—' : refType,
  };

  Map<String, Object?>? linked;
  if (table != null && refId.isNotEmpty) {
    try {
      final db = await ref.read(repoProvider).database;
      final rows = await db.query(
        table,
        where: 'id = ?',
        whereArgs: [refId],
        limit: 1,
      );
      if (rows.isNotEmpty) linked = rows.first;
    } catch (_) {}
  }

  final details = <(String, String)>[];
  void add(String label, Object? v) {
    final s = '$v'.trim();
    if (s.isNotEmpty && s != 'null') details.add((label, s));
  }

  if (linked != null) {
    add('الاسم', linked['name']);
    add('الرقم', linked['number']);
    add('البيان', linked['note'] ?? linked['description']);
    add('المبلغ', linked['amount']);
    add('العملة', linked['currency']);
    add('الكمية', linked['quantity']);
    add(
      'الحالة',
      switch ('${linked['status']}') {
        'approved' => 'معتمد',
        'draft' => 'مسودة',
        'cancelled' => 'ملغى',
        _ => '',
      },
    );
    final deleted = '${linked['deleted_at'] ?? ''}';
    if (deleted.isNotEmpty) details.add(('⚠️', 'هذا السجل محذوف حالياً'));
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.history, color: AppColors.primaryOf(ctx)),
      title: const Text('تفاصيل النشاط', style: TextStyle(fontSize: 17)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface2Of(ctx),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${a['text']}',
                style:
                    const TextStyle(fontWeight: FontWeight.w700, height: 1.6),
              ),
            ),
            const SizedBox(height: 12),
            _DetailRow(label: 'النوع', value: typeLabel),
            if (refId.isNotEmpty) _DetailRow(label: 'المعرّف', value: refId),
            _DetailRow(label: 'المنفّذ', value: '${a['user_name'] ?? '—'}'),
            if (created != null)
              _DetailRow(label: 'الوقت', value: Fmt.dateTime(created)),
            if (details.isNotEmpty) ...[
              const Divider(height: 20),
              Text(
                'بيانات السجل المرتبط',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text2Of(ctx),
                ),
              ),
              const SizedBox(height: 6),
              for (final d in details) _DetailRow(label: d.$1, value: d.$2),
            ] else if (table != null) ...[
              const SizedBox(height: 8),
              Text(
                'السجل المرتبط لم يعد موجوداً (حُذف أو استُبدل).',
                style: TextStyle(fontSize: 12, color: AppColors.text3Of(ctx)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('إغلاق'),
        ),
      ],
    ),
  );
}

/// سطر تفاصيل (تسمية: قيمة) داخل نافذة تفاصيل النشاط.
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.text3Of(context),
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}
