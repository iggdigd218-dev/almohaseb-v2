// شاشة الترحيب وتسجيل الدخول وإنشاء الحساب (Onboarding & Auth Gate):
//
// تصميم منظّم ومرتّب يفصل بوضوح بين:
//   0) المنشآت المحفوظة على هذا الجهاز (دخول وتبديل فوري بضغطة واحدة).
//   1) تسجيل الدخول لحساب مسجل مسبقاً (التعرف على الحساب واسترجاع منشأته من السحابة أو الجهاز).
//   2) إنشاء حساب ومنشأة جديدة (تأسيس منشأة بقاعدة بيانات SQLite معزولة nexora_${wsId}.db).
//   3) الانضمام لمنشأة قائمة كعضو / موظف (عبر رمز دعوة 6 أرقام أو باركود QR).
//   4) استخدام محلي مستقل (بدون بريد إلكتروني أو سحابة).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/accounting.dart';
import '../core/app_error_mapper.dart';
import '../core/cloud_config.dart';
import '../core/factory_reset.dart';
import '../core/security.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/cloud_control_service.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/device_id.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
import '../data/sync/subscription_guard.dart';
import 'account_section.dart' show provisionCloudAfterSignIn;
import 'create_workspace_screen.dart';
import 'recovery_wizard_screen.dart';
import 'group_management_screen.dart';
import 'home_shell.dart';
import 'join_approval_flow.dart';
import 'lock_gate.dart';
import 'qr_pair_scanner.dart';
import 'widgets.dart';

/// مفتاح علم «أُكمل الإعداد الأول» في جدول الإعدادات.
const kOnboardingDoneKey = 'has_completed_onboarding';

/// هل يجب عرض شاشة الإعداد الأول؟
/// تُعرض فقط إذا: لم يكتمل الإعداد من قبل، والوضع مستقل،
/// وقاعدة البيانات فارغة (لا حسابات إطلاقاً — مستخدم جديد كلياً).
/// أي حالة أخرى (ترقية تطبيق قائم، عضو مجموعة...) تُعلَّم مكتملة تلقائياً
/// حتى لا يُعاد الفحص في كل تشغيل.
Future<bool> shouldShowOnboarding(Repo repo) async {
  final st = await repo.settings();
  if (st[kOnboardingDoneKey] == '1') return false;
  final mode = await repo.workspaceMode();
  if (mode != 'standalone') {
    await repo.setSetting(kOnboardingDoneKey, '1');
    return false;
  }
  final accounts =
      await repo.accounts(includeArchived: true, includeDeleted: true);
  if (accounts.isNotEmpty) {
    await repo.setSetting(kOnboardingDoneKey, '1');
    return false;
  }
  return true;
}

/// يحفظ نتيجة الإعداد المصغّر ويعلّم الإعداد الأول مكتملاً.
/// لا يغيّر workspaceMode — الوضع المستقل هو الافتراضي أصلاً،
/// ومسار «متعدد الأجهزة» يمر عبر معالج المجموعة الذي يضبط الوضع بنفسه.
Future<void> completeOnboarding(
  Repo repo, {
  required String storeName,
  required String currencyCode,
  String phone = '',
  String activity = '',
  String email = '',
}) async {
  final name = storeName.trim().isEmpty ? 'متجري' : storeName.trim();
  await repo.setSetting('businessName', name);
  await repo.setSetting('defaultCurrency', currencyCode);
  if (phone.trim().isNotEmpty) {
    await repo.setSetting('phone', phone.trim());
    await repo.setSetting('whatsapp', phone.trim());
  }
  if (activity.trim().isNotEmpty) {
    await repo.setSetting('businessActivity', activity.trim());
  }
  if (email.trim().isNotEmpty) {
    await repo.setSetting('account.email', email.trim());
    await repo.setSetting('email', email.trim());
  }
  await repo.setSetting(kOnboardingDoneKey, '1');
}

class OnboardingScreen extends ConsumerStatefulWidget {
  final String? initialNotice;
  const OnboardingScreen({super.key, this.initialNotice});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscurePassword = true;
  String? _authError;

  String? _choice;
  String _name = '';
  final String _phone = '';
  final String _activity = '';
  String _currency = 'YER';
  bool _busy = false;
  List<WorkspaceInfo> _deviceWorkspaces = const [];
  bool _loadingWorkspaces = true;

  @override
  void initState() {
    super.initState();
    _loadSavedDeviceWorkspaces();
    if (widget.initialNotice != null && widget.initialNotice!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: Colors.amber, size: 24),
                SizedBox(width: 8),
                Text('تنبيه إنهاء الارتباط',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(widget.initialNotice!),
            actions: [
              FilledButton(
                // (PR-5) تطهير بقايا الطرد المحلية عند الإقرار بالتنبيه:
                // يبدأ العضو محاولته التالية من حالة نظيفة تماماً.
                onPressed: () async {
                  final nav = Navigator.of(dctx);
                  await _purgeLocalEjectionRemnants();
                  nav.pop();
                },
                child: const Text('حسناً فهمت'),
              ),
            ],
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  /// (PR-5) تطهير بقايا الطرد المحلية عند إقرار العضو بتنبيه إنهاء الارتباط
  /// أو قبل أي محاولة انضمام جديدة: أعلام العزل في sync_meta، ووسوم جهازنا
  /// في جدول الأجهزة، وسياق الانضمام المعلق، والمفاتيح العالقة في الذاكرة
  /// (بما فيها ما قد تخلفه إصدارات سابقة على الأجهزة).
  Future<void> _purgeLocalEjectionRemnants() async {
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      await db.delete('sync_meta',
          where:
              "key IN ('selfRevoked', 'demotedToAgentBy', 'workspaceStatus')");
      await db.delete('settings', where: "key LIKE 'pendingJoin.%'");
      try {
        final ourId = await ensureDeviceId(repo);
        await db.update(
          'devices',
          {
            'revoked_at': '',
            'expelled_at': '',
            'is_paired': 1,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [ourId],
        );
      } catch (_) {}
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in const [
        'ejected_flag',
        'is_ejected',
        'ejected',
        'ejection_dialog_pending',
        'last_ejection_reason',
        'auth_token',
      ]) {
        await prefs.remove(k);
      }
    } catch (_) {}
  }

  Future<void> _loadSavedDeviceWorkspaces() async {
    try {
      // (Self-Healing) مسح مسودات المنشآت الوهمية الفارغة من القرص قبل
      // عرض القائمة: أي nexora_WS-*.db بلا اسم تجاري حقيقي وبلا حسابات
      // أو حركات تُحذف تلقائياً، فلا تبقى في القائمة إلا منشأة المالك
      // المعتمدة الحقيقية.
      try {
        await AccountWorkspace.purgeGhostWorkspaceDatabasesOnDisk(
          currentWorkspaceId: ref.read(repoProvider).requireWorkspaceId,
        );
      } catch (_) {}
      final list = await AccountWorkspace.findLocalWorkspacesOnDevice();
      if (!mounted) return;
      setState(() {
        _deviceWorkspaces = list;
        _loadingWorkspaces = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingWorkspaces = false);
    }
  }

  void _invalidateAllSessionProviders() {
    ref.invalidate(googleLinkedProvider);
    ref.invalidate(currentUserProvider);
    ref.invalidate(deviceRoleProvider);
    ref.invalidate(effectivePermissionsProvider);
    ref.invalidate(canManageGroupProvider);
    ref.invalidate(settingsProvider);
    ref.invalidate(isOwnerProvider);
    ref.invalidate(workspaceModeProvider);
    ref.invalidate(subscriptionProvider);
    bump(ref);
  }

  /// الانتقال إلى الشاشة الرئيسية (وإلى معالج المجموعة عند الاختيار الشبكي).
  Future<void> _finishAndNavigate() async {
    if (!mounted) return;
    final nav = Navigator.of(context);
    final goNetwork = _choice == 'network';
    nav.pushReplacement(
      MaterialPageRoute(builder: (_) => const LockGate(child: HomeShell())),
    );
    if (goNetwork) {
      nav.push(
        MaterialPageRoute(builder: (_) => const GroupManagementScreen()),
      );
    }
  }

  /// فتح منشأة محفوظة مسبقاً على هذا الجهاز مباشرة بقاعدة بياناتها المعزولة.
  Future<void> _openSavedDeviceWorkspace(WorkspaceInfo ws) async {
    if (_busy) return;
    Sfx.click();
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);

      try {
        ref.read(syncEngineProvider).stop();
      } catch (_) {}

      final ok = await AccountWorkspace.switchToExistingWorkspace(
        repo,
        backendUrl: url,
        targetWorkspaceId: ws.workspaceId,
      );

      if (!ok) {
        if (mounted) {
          showSnack(context, 'تعذّر فتح المنشأة المحددة', error: true);
          setState(() => _busy = false);
        }
        return;
      }

      try {
        final engine = ref.read(syncEngineProvider);
        await engine.start();
        unawaited(engine.forceSyncNow());
      } catch (_) {}

      _invalidateAllSessionProviders();
      Sfx.success();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LockGate(child: HomeShell())),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'خطأ أثناء فتح المنشأة: $e', error: true);
      setState(() => _busy = false);
    }
  }

  /// حذف منشأة محفوظة فعلياً وبشكل صريح وقاطع من السحابة ومن هذا الجهاز.
  Future<void> _deleteSavedDeviceWorkspace(WorkspaceInfo ws) async {
    if (_busy) return;
    Sfx.click();
    final confirmed = await confirmDialog(
      context,
      title: 'حذف المنشأة نهائياً',
      message:
          'هل أنت متأكد من حذف منشأة «${ws.storeName}» (${ws.workspaceId}) نهائياً وبشكل قاطع من السحابة ومن هذا الجهاز؟\n\n'
          'سيتم مسح كافة بياناتها السحابية وقاعدة بياناتها المحلية ولا يمكن التراجع عن هذا الإجراء.',
      confirmText: 'حذف نهائياً',
      danger: true,
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);

      try {
        ref.read(syncEngineProvider).stop();
      } catch (_) {}

      await AccountWorkspace.deleteWorkspaceRegistration(
        repo,
        backendUrl: url,
        workspaceId: ws.workspaceId,
        ownerEmail: ws.ownerEmail,
        phone: ws.phone,
        deleteLocalDbFile: true,
      );

      await _loadSavedDeviceWorkspaces();
      if (!mounted) return;
      Sfx.success();
      showSnack(
        context,
        'تم حذف منشأة «${ws.storeName}» من السحابة ومن الجهاز نهائياً',
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'تعذّر حذف المنشأة: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// المتابعة بدون حساب سحابي — عمل محلي كامل ومستقل تماماً (ممنوع إنشاء مساحة عمل أو الارتباط بالسحابة).
  Future<void> _startLocal() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      try {
        ref.read(syncEngineProvider).stop();
      } catch (_) {}
      try {
        CloudControlService.instance.stop();
      } catch (_) {}
      await repo.setSetting('account.type', 'individual');
      await completeOnboarding(
        repo,
        storeName: _name,
        currencyCode: _currency,
        phone: _phone,
        activity: _activity,
      );
      await repo.setSetting('account.type', 'individual');
      await repo.setSetting('account.email', '');
      await repo.setSetting('email', '');
      await repo.setSetting('cloudWorkspaceProvisioned', '0');
      await repo.setSetting('sync.workspaceId', 'default');
      repo.debugSetWorkspaceId('default');
      try {
        final db = await repo.database;
        final now = DateTime.now().toIso8601String();
        await db.delete('workspaces', where: "id != 'default'");
        await db.insert(
          'workspaces',
          {
            'id': 'default',
            'name': _name.trim().isNotEmpty ? _name.trim() : 'متجري',
            'owner_google_id': '',
            'owner_email': '',
            'owner_name': '',
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await db.insert(
          'sync_meta',
          {'key': 'workspaceMode', 'value': 'standalone'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}
      await repo.restoreManagerOwnership(syncToCloud: false);
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      _invalidateAllSessionProviders();
      await _finishAndNavigate();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// فحص واسترجاع المنشأة لحساب مصادق عليه أو تحويله تلقائياً لشاشة إنشاء حساب جديد
  /// مع تعبئة البريد الإلكتروني مسبقاً في حال عدم وجود منشأة سابقة.
  Future<void> _resolveWorkspaceOrRedirectToRegister({
    required FirebaseAccount account,
    required bool isLoginFlow,
  }) async {
    final repo = ref.read(repoProvider);
    FirebaseAuthRest.primeAccountInMemory(account);
    final cleanAuthEmail = account.email.trim().toLowerCase();
    if (cleanAuthEmail.isNotEmpty) {
      await repo.setSetting('account.email', cleanAuthEmail);
      await repo.setSetting('email', cleanAuthEmail);
    }
    final st = await repo.settings();
    final url = effectiveBackendUrl(st['cloudBackendUrl']);

    final devId = await ensureDeviceId(repo);
    final rawFp =
        await SubscriptionGuard.hardwareFingerprintRaw() ?? 'fallback:$devId';
    final hwFp = SubscriptionGuard.fingerprintHash(rawFp);

    final localMatches = await AccountWorkspace.findLocalWorkspacesOnDevice(
      filterEmail: account.email,
    );
    CloudWorkspaceResolution cloudRes =
        const CloudWorkspaceResolution.notFound();
    if (url.isNotEmpty) {
      try {
        cloudRes = await AccountWorkspace.resolveWorkspaceInCloud(
          backendUrl: url,
          email: account.email,
          uid: account.uid,
          deviceId: devId,
          deviceFingerprint: hwFp,
        ).timeout(
          const Duration(seconds: 12),
          onTimeout: () => const CloudWorkspaceResolution.timeout(),
        );
      } catch (_) {
        cloudRes = const CloudWorkspaceResolution.networkError();
      }
    }

    final hasExistingWorkspace = cloudRes.found || localMatches.isNotEmpty;

    // في حال فشل الاتصال أو انتهاء المهلة وعدم وجود نسخة محلية مطابقة:
    // يُمنع التوجيه لشاشة إنشاء المنشأة ويُمنع استدعاء linkAccountOnly(forceIsolateNewUser: true)
    if (!hasExistingWorkspace && cloudRes.isNetworkOrTimeoutError) {
      if (!mounted) return;
      final retry = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.wifi_off_rounded, color: Colors.orange, size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'تعذر التحقق من الحساب',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: const Text(
            'تعذر التحقق من حسابك بسبب بطء أو انقطاع الاتصال.. يرجى إعادة المحاولة',
            style: TextStyle(fontSize: 13.5, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dctx).pop(true),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
      if (retry == true && mounted) {
        await _resolveWorkspaceOrRedirectToRegister(
          account: account,
          isLoginFlow: isLoginFlow,
        );
      }
      return;
    }

    // ══ (إصلاح المنشآت الوهمية) المنشأة المحلية المعتمدة أولى من كل شيء ══
    // إن وُجد على هذا الهاتف منشأة محفوظة لهذا البريد المسجل باسم تجاري
    // حقيقي وبيانات مسجلة سابقة، فهي وجهة الدخول المباشرة المعتمدة.
    WorkspaceInfo? trustedLocal;
    for (final w in localMatches) {
      final sn = w.storeName.trim();
      final hasRealName = sn.isNotEmpty &&
          sn != 'متجري' &&
          sn != 'منشأتي' &&
          !sn.startsWith('منشأة (') &&
          !sn.startsWith('منشأة(');
      if (hasRealName) {
        trustedLocal = w;
        break;
      }
    }

    final existingWsId = trustedLocal?.workspaceId ??
        (cloudRes.found
            ? cloudRes.workspaceId
            : (localMatches.isNotEmpty
                ? localMatches.first.workspaceId
                : ''));
    final existingStoreName = (cloudRes.meta?['storeName'] ??
            cloudRes.meta?['store_name'] ??
            cloudRes.meta?['businessName'] ??
            (localMatches.isNotEmpty ? localMatches.first.storeName : ''))
        .toString()
        .trim();

    if (!isLoginFlow && hasExistingWorkspace && existingWsId.isNotEmpty) {
      if (!mounted) return;
      final decision = await showDialog<String>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text(
            'البريد الإلكتروني مسجل مسبقاً',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          content: Text(
            'البريد الإلكتروني (${account.email}) مرتبط بمنشأة مسجلة مسبقاً'
            '${existingStoreName.isNotEmpty ? ' باسم «$existingStoreName»' : ''}.\n\n'
            'لا يُسمح بإنشاء أكثر من منشأة بنفس البريد الإلكتروني. هل ترغب بفتح منشأتك الحالية؟',
            style: const TextStyle(fontSize: 13.5, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop('cancel'),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop('restore'),
              child: const Text('فتح منشأتي السابقة'),
            ),
          ],
        ),
      );

      if (decision == 'cancel' || decision == null || !mounted) return;
    }

    if (hasExistingWorkspace && existingWsId.isNotEmpty) {
      bool restored = false;
      var didStopSyncEngine = false;

      // ══ (إصلاح المنشآت الوهمية) التوجيه المباشر للمنشأة المعتمدة ══
      // عند وجود منشأة محفوظة معتمدة على هذا الهاتف للبريد المسجل، يتم
      // الانتقال إليها فوراً عبر switchToExistingWorkspace — دون المرور
      // بأي مسار توليد مسودات أو إنشاء قواعد بيانات جديدة خلف المستخدم.
      if (trustedLocal != null) {
        try {
          try {
            ref.read(syncEngineProvider).stop();
            didStopSyncEngine = true;
          } catch (_) {}
          restored = await AccountWorkspace.switchToExistingWorkspace(
            repo,
            backendUrl: url,
            targetWorkspaceId: trustedLocal.workspaceId,
          );
        } catch (_) {
          restored = false;
        }
      }

      if (!restored && url.isNotEmpty) {
        try {
          final outcome = await AccountWorkspace.linkAccountOnly(
            repo,
            backendUrl: url,
            account: account,
            forceIsolateNewUser: false,
          ).timeout(const Duration(seconds: 35));
          restored = outcome == AccountLinkOutcome.switched ||
              outcome == AccountLinkOutcome.migrated ||
              outcome == AccountLinkOutcome.recovered;
        } catch (_) {}
      }

      if (!restored) {
        restored = await AccountWorkspace.switchToExistingWorkspace(
          repo,
          backendUrl: url,
          targetWorkspaceId: existingWsId,
        );
      }

      if (restored) {
        // إعادة تشغيل محرك المزامنة إن كنا قد أوقفناه للتبديل المباشر.
        if (didStopSyncEngine) {
          try {
            final engine = ref.read(syncEngineProvider);
            await engine.start();
            unawaited(engine.forceSyncNow());
          } catch (_) {}
        }
        await repo.setSetting('account.type', 'enterprise');
        await repo.setSetting(kOnboardingDoneKey, '1');
        await repo.setSetting('onboardingCompleted', '1');
        await FirebaseAuthRest.saveSession(repo, account);
        if (account.email.trim().isNotEmpty) {
          await repo.setSetting('account.email', account.email.trim());
          await repo.setSetting('email', account.email.trim());
          try {
            final targetDb = await repo.database;
            await GoogleAuthService(targetDb).persistAccount(
              googleId: account.uid,
              email: account.email,
              displayName: account.displayName,
              idToken: account.idToken,
            );
          } catch (_) {}
        }
        if (url.isNotEmpty) {
          await repo.setSetting('cloudWorkspaceProvisioned', '1');
          unawaited(provisionCloudAfterSignIn(repo, ref, url));
        }

        _invalidateAllSessionProviders();
        Sfx.success();
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(
              builder: (_) => const LockGate(child: HomeShell())),
          (route) => false,
        );
        return;
      }
    }

    // إذا كان تدفق تسجيل دخول عادي ولم يُعثر على أي منشأة سابقة:
    // إشعار المستخدم صراحة بعدم وجود حساب أو منشأة مسجلة دون إدخاله لمنشأة فارغة جديدة رغماً عنه
    if (isLoginFlow) {
      if (!mounted) return;
      setState(() {
        _authError =
            'لا توجد منشأة سابقة مسجلة للبريد ($cleanAuthEmail).\nإذا كنت ترغب بتأسيس منشأة جديدة، اضغط على «تسجيل حساب جديد وتأسيس منشأة».';
      });
      Sfx.error();
      return;
    }

    // في حال تدفق إنشاء حساب جديد وتأكد عدم وجود منشأة مسجلة (notFound):
    // حفظ جلسة الحساب فقط دون توليد أو عزل WS-* وهمي، والتوجيه لشاشة إعداد المنشأة
    await FirebaseAuthRest.saveSession(repo, account);
    if (cleanAuthEmail.isNotEmpty) {
      await repo.setSetting('account.email', cleanAuthEmail);
      await repo.setSetting('email', cleanAuthEmail);
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => CreateWorkspaceScreen(
          ownerEmail: account.email,
          ownerUid: account.uid,
          ownerDisplayName: account.displayName,
        ),
      ),
    );
  }

  void _openCreateWorkspace() {
    final raw = _emailCtrl.text.trim().toLowerCase();
    final email = raw.contains('@') ? raw : '';
    final password = _passwordCtrl.text;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => CreateWorkspaceScreen(
          ownerEmail: email,
          initialPassword: password,
        ),
      ),
    );
  }

  /// فتح صفحة استعادة كلمة السر الموثقة (عبر رمز من الإدارة/مساعد الذكاء الاصطناعي أو رابط البريد الرسمي).
  Future<void> _openForgotPasswordScreen() async {
    if (_busy) return;
    Sfx.click();
    final raw = _emailCtrl.text.trim();
    final initialEmail = raw.contains('@') ? raw : '';
    final initialPhone = !raw.contains('@') ? raw : '';

    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<bool>(
        builder: (_) => RecoveryWizardScreen(
          initialIdentifier:
              initialEmail.isNotEmpty ? initialEmail : initialPhone,
          countryDialCode: '+967',
        ),
      ),
    );
  }

  /// (R-05) فتح المنشأة بعد تحقّق قراءة-فقط من البصمة التي اعتمدها المشرف
  /// عبر `adminUpdateWorkspacePassword`. لا يُنشأ حساب ولا تُكتب أي بيانات.
  Future<void> _openVerifiedCloudWorkspace(
    PhoneWorkspaceRecoveryResult rec,
  ) async {
    final effectiveEmail = rec.ownerEmail.trim().isNotEmpty
        ? rec.ownerEmail.trim().toLowerCase()
        : 'phone.${rec.workspaceId.toLowerCase()}@nexora.local';
    final account = FirebaseAccount(
      uid: 'email:${AccountWorkspace.emailToKey(effectiveEmail)}',
      email: effectiveEmail,
      displayName: rec.storeName,
    );
    await _resolveWorkspaceOrRedirectToRegister(
      account: account,
      isLoginFlow: true,
    );
  }

  /// تسجيل الدخول عبر البريد الإلكتروني وكلمة المرور حصراً عبر Firebase Auth الرسمي أو المنشأة المحلية الموثقة.
  Future<void> _handleEmailLogin() async {
    if (_busy) return;
    final rawInput = _emailCtrl.text.trim();
    final email = rawInput.toLowerCase();
    final password = _passwordCtrl.text;
    final isEmailInput = email.contains('@');
    final digits = rawInput.replaceAll(RegExp(r'[^\d]'), '');

    if (!isEmailInput && digits.length < 7) {
      setState(() => _authError =
          'أدخل البريد الإلكتروني أو رقم الهاتف المسجل، وكلمة المرور — أو سجل الدخول عبر (حساب Google)');
      Sfx.error();
      return;
    }
    if (isEmailInput && !email.contains('.')) {
      setState(() => _authError = 'يرجى إدخال بريد إلكتروني صحيح');
      Sfx.error();
      return;
    }
    if (password.trim().length < 4) {
      setState(() => _authError = 'يرجى إدخال كلمة المرور (4 أحرف على الأقل)');
      Sfx.error();
      return;
    }

    Sfx.click();
    setState(() {
      _busy = true;
      _authError = null;
    });

    // 1) فحص فوري للمنشآت المحفوظة محلياً على الجهاز لنفس البريد الإلكتروني
    if (isEmailInput) {
      try {
        final localMatches = await AccountWorkspace.findLocalWorkspacesOnDevice(
          filterEmail: email,
        );
        if (localMatches.isNotEmpty) {
          await _openSavedDeviceWorkspace(localMatches.first);
          return;
        }
      } catch (_) {}
    }

    // 2) المصادقة الرسمية عبر Firebase Auth أولاً (المسار الأساسي دائمًا).
    //    رقم الهاتف يُترجم إلى بريده الداخلي المعياري (أو بريده المرتبط).
    {
      String authEmail = isEmailInput
          ? email
          : AccountWorkspace.internalEmailForPhone(rawInput);
      if (!isEmailInput) {
        try {
          final st0 = await ref.read(repoProvider).settings();
          final url0 = effectiveBackendUrl(st0['cloudBackendUrl']);
          if (url0.isNotEmpty) {
            final found =
                await AccountWorkspace.lookupWorkspaceByPhoneForRecovery(
              backendUrl: url0,
              phone: rawInput,
              countryDialCode: '+967',
            );
            if (found != null && found.ownerEmail.contains('@')) {
              authEmail = found.ownerEmail.toLowerCase();
            }
          }
        } catch (_) {}
      }
      try {
        final account = await FirebaseAuthRest.signInWithEmailPassword(
          email: authEmail,
          password: password,
        );
        await _resolveWorkspaceOrRedirectToRegister(
          account: account,
          isLoginFlow: true,
        );
        return;
      } on StateError catch (se) {
        final msg = se.message;
        final credentialsFailure = msg.contains('USER_NOT_FOUND') ||
            msg.contains('INVALID_CREDENTIALS_OR_NOT_FOUND') ||
            msg.contains('INVALID_PASSWORD') ||
            msg.contains('EMAIL_NOT_FOUND');
        if (!credentialsFailure) {
          if (!mounted) return;
          setState(() => _authError = msg);
          Sfx.error();
          setState(() => _busy = false);
          return;
        }
        // فشل معتاد ⇒ نكمل إلى المسار الرديف.
      } catch (e) {
        if (!mounted) return;
        setState(() => _authError = AppErrorMapper.toUserFriendlyMessage(e));
        Sfx.error();
        setState(() => _busy = false);
        return;
      }
    }

    // 3) (R-05) مسار رديف للمالك الذي عيّن له المشرف كلمة مرور عبر لوحة
    //    الإدارة: تحقّق **قراءة فقط** من `meta.password_hash` — بلا أي كتابة.
    try {
      final repo = ref.read(repoProvider);
      final st2 = await repo.settings();
      final url2 = effectiveBackendUrl(st2['cloudBackendUrl']);
      if (url2.isNotEmpty) {
        final verified = await AccountWorkspace.verifyWorkspacePasswordInCloud(
          backendUrl: url2,
          emailOrPhone: rawInput,
          password: password,
        );
        if (verified != null) {
          await _openVerifiedCloudWorkspace(verified);
          return;
        }
      }
    } catch (_) {}

    // 4) لا Firebase Auth ولا بصمة معتمدة ⇒ رسالة موحّدة بلا كشف تفاصيل.
    if (mounted) {
      setState(() => _authError =
          'بيانات الدخول غير صحيحة أو الحساب غير مسجل.\nإذا نسيت كلمة السر اضغط على «نسيت كلمة السر؟» بالأسفل، أو سجل الدخول عبر (حساب Google).');
      setState(() => _busy = false);
    }
    Sfx.error();
  }

  /// المسار الموحّد لتسجيل الدخول أو إنشاء حساب عبر Google.
  Future<void> _handleGoogleAuthFlow({required bool isLoginFlow}) async {
    if (_busy) return;
    Sfx.click();
    setState(() {
      _busy = true;
      _authError = null;
    });

    final repo = ref.read(repoProvider);
    final db = await repo.database;
    if (!mounted) {
      setState(() => _busy = false);
      return;
    }
    final auth = GoogleAuthService(db);

    try {
      final r = await auth.signIn(forceAccountPicker: true).timeout(
            const Duration(seconds: 45),
            onTimeout: () => const GoogleAuthResult.fail(
                'انتهت مهلة استجابة Google — تأكد من الاتصال وأعد المحاولة.'),
          );

      if (!mounted) return;

      final gu = r.user;
      if (gu == null) {
        Sfx.error();
        if (r.error != 'تم إلغاء تسجيل الدخول') {
          setState(() =>
              _authError = r.error ?? 'تعذّر تسجيل الدخول بحساب Google');
        }
        return;
      }

      FirebaseAccount? account;
      try {
        account = await FirebaseAuthRest.signInWithGoogleIdToken(
          gu.idToken ?? '',
          accessToken: gu.accessToken,
          email: gu.email,
          googleId: gu.id,
          displayName: gu.displayName ?? '',
        ).timeout(const Duration(seconds: 15));
      } catch (_) {}
      account ??= FirebaseAccount(
        uid: gu.id.isNotEmpty
            ? gu.id
            : 'email:${AccountWorkspace.emailToKey(gu.email)}',
        email: gu.email.trim().toLowerCase(),
        displayName: gu.displayName ?? '',
      );

      await _resolveWorkspaceOrRedirectToRegister(
        account: account,
        isLoginFlow: isLoginFlow,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _authError = AppErrorMapper.toUserFriendlyMessage(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// نافذة الانضمام لمنشأة قائمة كعضو / موظف عبر رمز دعوة (6 أرقام) أو باركود QR.
  Future<void> _openJoinMemberDialog() async {
    if (_busy) return;
    Sfx.click();
    await showDialog<void>(
      context: context,
      builder: (ctx) => _JoinMemberDialog(
        onJoined: () {
          _invalidateAllSessionProviders();
        },
      ),
    );
  }

  /// نافذة الاستخدام المحلي المستقل (بدون بريد إلكتروني).
  Future<void> _openLocalStandaloneDialog() async {
    if (_busy) return;
    Sfx.click();
    setState(() => _choice = 'personal');
    await showDialog<void>(
      context: context,
      builder: (ctx) => _LocalStandaloneDialog(
        initialName: _name,
        initialCurrency: _currency,
        onConfirm: (name, currency) async {
          _name = name;
          _currency = currency;
          Navigator.of(ctx).pop();
          await _startLocal();
        },
      ),
    );
  }

  /// «حذف كامل من كل مكان»: الجهاز + السحابة.
  Future<void> _purgeEverything() async {
    if (_busy) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف كامل من الجهاز والسحابة'),
        content: const Text(
          'سيُحذف كل شيء نهائياً ومن كل مكان:\n\n'
          '• كل البيانات المحلية على هذا الجهاز.\n'
          '• كل بياناتك من السحابة (المساحة، النسخ، السجل).\n'
          '• موقع جهازك في مجموعته (إن كان عضواً) وبصمة الجهاز وفهرس '
          'حساب Google.\n\n'
          'بعد هذا الحذف لا يمكن استرجاع بياناتك ولا موقعك في المجموعة '
          'أبداً. يُستثنى الاشتراك المدفوع فقط.\n\n'
          'هل أنت متأكد تماماً؟',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف كل شيء من كل مكان'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final authed = await Security.authenticate(
      reason: 'أكّد هويتك للحذف الكامل من الجهاز والسحابة',
    );
    if (!authed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('لم تكتمل المصادقة — أُلغي الحذف')));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final engine = ref.read(syncEngineProvider);
      try {
        engine.stop();
      } catch (_) {}
      try {
        final st = await repo.settings();
        final url = effectiveBackendUrl(st['cloudBackendUrl']);
        if (url.isNotEmpty) {
          await CloudJoin.purgeDeviceEverywhere(repo, backendUrl: url);
        }
        final db = await repo.database;
        try {
          await GoogleAuthService(db).signOut();
        } catch (_) {}
      } catch (_) {}
      await FactoryReset.wipeAllLocalData();
      await FirebaseAuthRest.purgeAllSessionPrefs(clearWorkspacesList: true);
      Sfx.success();
      try {
        await repo.initSyncInfra().timeout(const Duration(seconds: 8));
      } catch (_) {}
      try {
        await engine.start();
      } catch (_) {}
      if (!mounted) return;
      await _loadSavedDeviceWorkspaces();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('تم الحذف الكامل — الجهاز والسحابة نظيفان'),
          backgroundColor: Color(0xFF16A34A)));
      setState(() => _choice = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّر الحذف الكامل: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppColors.primaryOf(context);
    final surface = Theme.of(context).colorScheme.surface;
    final divider = Theme.of(context).dividerColor;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
              children: [
                Text(
                  'تسجيل الدخول وإدارة الحساب',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'أدخل بريدك الإلكتروني للدخول إلى منشأتك أو إنشاء حساب جديد',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: AppColors.text2Of(context),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 22),

                // ---------- المنشآت المحفوظة على هذا الجهاز (إن وجدت) ----------
                if (!_loadingWorkspaces && _deviceWorkspaces.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: primary.withValues(alpha: 0.24),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'المنشآت المحفوظة على هذا الجهاز',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                            Text(
                              '${_deviceWorkspaces.length}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        for (final ws in _deviceWorkspaces)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: surface,
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: _busy
                                    ? null
                                    : () => _openSavedDeviceWorkspace(ws),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: divider),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              ws.storeName,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 13.5,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              [
                                                if (ws.ownerEmail.isNotEmpty)
                                                  ws.ownerEmail,
                                                if (ws.businessActivity
                                                    .isNotEmpty)
                                                  ws.businessActivity,
                                                ws.defaultCurrency,
                                              ].join(' • '),
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                color:
                                                    AppColors.text2Of(context),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      FilledButton.tonal(
                                        onPressed: _busy
                                            ? null
                                            : () =>
                                                _openSavedDeviceWorkspace(ws),
                                        child: const Text('دخول'),
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        tooltip:
                                            'حذف المنشأة نهائياً من السحابة والجهاز',
                                        icon: const Icon(
                                          Icons.delete_forever_rounded,
                                          color: Colors.redAccent,
                                          size: 22,
                                        ),
                                        onPressed: _busy
                                            ? null
                                            : () =>
                                                _deleteSavedDeviceWorkspace(ws),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                ],

                // ---------- 1. بطاقة البدء في الاستخدام المحلي المستقل (بارزة ومباشرة) ----------
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFD97706).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFD97706).withValues(alpha: 0.32),
                    ),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _busy ? null : _openLocalStandaloneDialog,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: const Color(0xFFD97706)
                                    .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.flash_on_rounded,
                                color: Color(0xFFD97706),
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'الاستخدام المحلي المستقل',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    'بدء العمل فوراً على هذا الهاتف بدون إنترنت أو حساب',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.arrow_forward_ios_rounded,
                              size: 15,
                              color: Color(0xFFD97706),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ---------- 2. بطاقة تسجيل الدخول السحابي ----------
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: divider),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_authError != null) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: Colors.redAccent.withValues(alpha: 0.5)),
                          ),
                          child: Text(
                            _authError!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      TextField(
                        controller: _emailCtrl,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        textDirection: TextDirection.ltr,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'البريد الإلكتروني',
                          hintText: 'name@example.com',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passwordCtrl,
                        enabled: !_busy,
                        obscureText: _obscurePassword,
                        textDirection: TextDirection.ltr,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _handleEmailLogin(),
                        decoration: InputDecoration(
                          labelText: 'كلمة المرور',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: _busy ? null : _openForgotPasswordScreen,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(
                            Icons.lock_reset_rounded,
                            size: 18,
                          ),
                          label: const Text(
                            'نسيت كلمة السر؟',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: _busy ? null : () => _handleEmailLogin(),
                          child: _busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'تسجيل الدخول',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // سطر متوازن: تسجيل حساب جديد (يمين) | أيقونة Google (يسار)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                            onPressed: _busy ? null : _openCreateWorkspace,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 6),
                            ),
                            child: const Text(
                              'تسجيل حساب جديد وتأسيس منشأة',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: _busy
                                ? null
                                : () =>
                                    _handleGoogleAuthFlow(isLoginFlow: true),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: divider),
                                color: surface,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 22,
                                    height: 22,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFF4285F4),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Text(
                                      'G',
                                      style: TextStyle(
                                        fontFamily: 'Roboto',
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    'حساب Google',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ---------- 3. خيار الانضمام كعضو / كاشير عبر QR ----------
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _openJoinMemberDialog,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                    label: const Text(
                      'انضمام كعضو لمحل قائم (رمز / باركود QR)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 18),
                Center(
                  child: TextButton(
                    onPressed: _busy ? null : _purgeEverything,
                    child: const Text(
                      'حذف كامل من الجهاز والسحابة',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// نافذة الانضمام لمنشأة قائمة كعضو عبر رمز 6 أرقام أو مسح QR.
class _JoinMemberDialog extends ConsumerStatefulWidget {
  final VoidCallback onJoined;
  const _JoinMemberDialog({required this.onJoined});

  @override
  ConsumerState<_JoinMemberDialog> createState() => _JoinMemberDialogState();
}

class _JoinMemberDialogState extends ConsumerState<_JoinMemberDialog> {
  final _deviceNameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _deviceNameCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitJoin({PairingData? qrData}) async {
    if (_busy) return;
    final repo = ref.read(repoProvider);
    final devName = _deviceNameCtrl.text.trim().isNotEmpty
        ? _deviceNameCtrl.text.trim()
        : 'جهاز عضو';

    String tokenOrPin = _pinCtrl.text.trim();
    String targetWs = '';
    final st = await repo.settings();
    String backendUrl = effectiveBackendUrl(st['cloudBackendUrl']);

    if (qrData != null) {
      tokenOrPin = qrData.tok.trim();
      targetWs = qrData.ws.trim();
      if (qrData.cloudUrl.trim().isNotEmpty) {
        backendUrl = qrData.cloudUrl.trim();
      }
    }

    if (!mounted) return;
    if (tokenOrPin.isEmpty) {
      showSnack(context, 'أدخل رمز الدعوة (6 أرقام) أو امسح باركود QR أولاً',
          error: true);
      return;
    }

    final pendingCount = await repo.pendingSyncOperationsCount();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: Colors.orange, size: 40),
        title: const Text('تحذير: الانضمام لمنشأة قائمة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'الانضمام إلى هذه المنشأة سيؤدي إلى استبدال كافة البيانات والعمليات المحلية المسجلة على هذا الهاتف بنسخة المنشأة السحابية. هل ترغب بالاستمرار؟',
              style: TextStyle(height: 1.7),
            ),
            if (pendingCount > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'تنبيه هام: لديك ($pendingCount) عملية محلية غير متزامنة في طابور المزامنة ستُفقد نهائياً عند المتابعة.',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.red,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('أوافق — استبدال البيانات والانضمام'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    Sfx.click();
    try {
      if (targetWs.isEmpty || targetWs == 'default') {
        final foundWs = await CloudJoin.findWorkspaceByInvite(
          backendUrl: backendUrl,
          tokenOrPin: tokenOrPin,
        );
        if (foundWs != null && foundWs.isNotEmpty) {
          targetWs = foundWs;
        }
      }
      if (targetWs.isEmpty) targetWs = 'default';

      await CloudJoin.purgeAndIsolateJoiningMember(
        repo,
        backendUrl: backendUrl,
        targetWorkspaceId: targetWs,
      );

      await CloudJoin.requestJoin(
        repo,
        backendUrl: backendUrl,
        tokenOrPin: tokenOrPin,
        deviceName: devName,
        workspaceId: targetWs,
      );
      final savedWs = (await repo.settings())['pendingJoin.ws'] ?? targetWs;
      if (!mounted) return;
      final nav = Navigator.of(context, rootNavigator: true);
      Navigator.of(context).pop();
      await nav.push(
        MaterialPageRoute<void>(
          builder: (_) => JoinApprovalScreen(
            prefillUrl: backendUrl,
            prefillWs: savedWs,
            prefillToken: tokenOrPin,
            startWaiting: true,
          ),
        ),
      );
      widget.onJoined();
    } on CloudJoinException catch (e) {
      Sfx.error();
      if (mounted) showSnack(context, e.message, error: true);
    } catch (e) {
      Sfx.error();
      if (mounted) {
        showSnack(context, 'تعذّر إرسال طلب الانضمام: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanQr() async {
    final data = await scanQrPair(context);
    if (data == null || !mounted) return;
    if (!data.isCloud || data.tok.trim().isEmpty) {
      showSnack(context, 'رمز QR غير صالح — تأكد أنه رمز دعوة سحابية.',
          error: true);
      return;
    }
    await _submitJoin(qrData: data);
  }

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF7C3AED);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.group_add_rounded,
                        color: color, size: 26),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'الانضمام لمنشأة قائمة',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'أدخل اسمك الوظيفي أو اسم هذا الجهاز، ثم أدخل رمز الدعوة المكون من 6 أرقام الصادر من جهاز مدير المنشأة أو امسح باركود QR:',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: AppColors.text2Of(context),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _deviceNameCtrl,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'اسم الموظف / هذا الجهاز',
                  hintText: 'مثال: كاشير الفرع الرئيسي',
                  prefixIcon: Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _pinCtrl,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 12,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z\-]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'رمز الدعوة (6 أرقام)',
                  hintText: '123456',
                  counterText: '',
                  prefixIcon: Icon(Icons.pin_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: color),
                  onPressed: _busy ? null : () => _submitJoin(),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.login_rounded),
                  label: const Text(
                    'إرسال طلب الانضمام للمنشأة',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 46,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _scanQr,
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('مسح باركود الدعوة (QR)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// نافذة الاستخدام المحلي المستقل (بدون بريد إلكتروني).
class _LocalStandaloneDialog extends StatefulWidget {
  final String initialName;
  final String initialCurrency;
  final Future<void> Function(String name, String currency) onConfirm;

  const _LocalStandaloneDialog({
    required this.initialName,
    required this.initialCurrency,
    required this.onConfirm,
  });

  @override
  State<_LocalStandaloneDialog> createState() => _LocalStandaloneDialogState();
}

class _LocalStandaloneDialogState extends State<_LocalStandaloneDialog> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.initialName);
  late String _currency = widget.initialCurrency;
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFD97706);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.storefront_rounded,
                        color: color, size: 26),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'إعداد الاستخدام المحلي المستقل',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'سيتم حفظ بياناتك محلياً على هذا الجهاز فقط. يمكنك لاحقاً ربط حساب Google وتفعيل المزامنة السحابية في أي وقت من الملف الشخصي.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: AppColors.text2Of(context),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameCtrl,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'اسم المتجر / النشاط',
                  hintText: 'مثال: متجر الأمانة',
                  prefixIcon: Icon(Icons.store_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'العملة الأساسية',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in kDefaultCurrencies)
                    ChoiceChip(
                      label: Text('${c.symbol} ${c.code}'),
                      selected: _currency == c.code,
                      onSelected: (_) => setState(() => _currency = c.code),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _busy = true);
                          final name = _nameCtrl.text.trim().isEmpty
                              ? 'متجري'
                              : _nameCtrl.text.trim();
                          widget.onConfirm(name, _currency);
                        },
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text(
                    'البدء محلياً الآن',
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// صفحة استعادة كلمة السر الموثقة (عبر طلب مشفر لمساعد الإدارة الذكي أو رابط البريد الرسمي).
/// يُمنع منعاً باتاً تعيين كلمة مرور جديدة من طرف العميل مباشرة دون تحقق ملكية حقيقي.
class ForgotPasswordRecoveryScreen extends ConsumerStatefulWidget {
  final String initialEmail;
  final String initialPhone;

  const ForgotPasswordRecoveryScreen({
    super.key,
    this.initialEmail = '',
    this.initialPhone = '',
  });

  @override
  ConsumerState<ForgotPasswordRecoveryScreen> createState() =>
      _ForgotPasswordRecoveryScreenState();
}

class _ForgotPasswordRecoveryScreenState
    extends ConsumerState<ForgotPasswordRecoveryScreen> {
  static const _dialCodes = <(String, String)>[
    ('+967', 'اليمن (+967)'),
    ('+966', 'السعودية (+966)'),
    ('+971', 'الإمارات (+971)'),
    ('+968', 'عُمان (+968)'),
    ('+965', 'الكويت (+965)'),
    ('+974', 'قطر (+974)'),
    ('+973', 'البحرين (+973)'),
    ('+20', 'مصر (+20)'),
    ('+962', 'الأردن (+962)'),
    ('+964', 'العراق (+964)'),
  ];

  // 'admin_whatsapp' | 'email_link'
  String _mode = 'admin_whatsapp';
  String _countryDialCode = '+967';
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  String _deviceId = '';
  String _hwFingerprint = '';
  String? _generatedAiPacket;
  bool _busy = false;
  String? _errorMsg;
  String? _successMsg;

  @override
  void initState() {
    super.initState();
    _phoneCtrl = TextEditingController(text: widget.initialPhone);
    _emailCtrl = TextEditingController(text: widget.initialEmail);
    _loadDeviceIdentity();
  }

  Future<void> _loadDeviceIdentity() async {
    try {
      final repo = ref.read(repoProvider);
      final devId = await ensureDeviceId(repo);
      final rawFp =
          await SubscriptionGuard.hardwareFingerprintRaw() ?? 'fallback:$devId';
      final hwFp = SubscriptionGuard.fingerprintHash(rawFp);
      if (!mounted) return;
      setState(() {
        _deviceId = devId;
        _hwFingerprint = hwFp;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  /// يرجع `true` إذا فُتح واتساب فعلًا (لتظهر النتيجة للمستخدم بصدق).
  Future<bool> _launchWhatsAppMessage({
    required String targetPhone,
    required String message,
  }) async {
    final cleanDigits = targetPhone.replaceAll(RegExp(r'[^\d]'), '');
    final encoded = Uri.encodeComponent(message);
    final nativeUri =
        Uri.parse('whatsapp://send?phone=$cleanDigits&text=$encoded');
    final webUri = Uri.parse('https://wa.me/$cleanDigits?text=$encoded');
    try {
      if (await canLaunchUrl(nativeUri)) {
        await launchUrl(nativeUri, mode: LaunchMode.externalApplication);
        return true;
      }
    } catch (_) {}
    try {
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// إرسال طلب استعادة مشفر برمجياً (`nexora-ai-rpc`) إلى الإدارة ومساعد خدمة العملاء الذكي عبر واتساب.
  Future<void> _requestRecoveryFromAdminSmartSupport() async {
    if (_busy) return;
    final rawPhone = _phoneCtrl.text.trim();
    final digits = rawPhone.replaceAll(RegExp(r'[^\d]'), '');
    final rawEmail = _emailCtrl.text.trim().toLowerCase();

    if (digits.length < 7 && (rawEmail.isEmpty || !rawEmail.contains('@'))) {
      setState(() {
        _errorMsg =
            'يرجى إدخال رقم الهاتف المسجل للمنشأة (أو البريد الإلكتروني) لإصدار كود التحقق للإدارة';
        _successMsg = null;
      });
      Sfx.error();
      return;
    }

    setState(() {
      _busy = true;
      _errorMsg = null;
      _successMsg = null;
    });

    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);

      final devId = _deviceId.isNotEmpty ? _deviceId : await ensureDeviceId(repo);
      final rawFp =
          await SubscriptionGuard.hardwareFingerprintRaw() ?? 'fallback:$devId';
      final hwFp = _hwFingerprint.isNotEmpty
          ? _hwFingerprint
          : SubscriptionGuard.fingerprintHash(rawFp);

      final dialDigits = _countryDialCode.replaceAll(RegExp(r'[^\d]'), '');
      final localDigits =
          digits.startsWith('0') ? digits.substring(1) : digits;
      final fullPhone = digits.isNotEmpty
          ? (digits.startsWith(dialDigits)
              ? '+$digits'
              : '$_countryDialCode$localDigits')
          : '';

      String resolvedWsId = '';
      String resolvedStoreName = '';
      String resolvedEmail = rawEmail;

      if (digits.length >= 7) {
        final found = await AccountWorkspace.lookupWorkspaceByPhoneForRecovery(
          backendUrl: url,
          phone: rawPhone,
          countryDialCode: '+967',
        );
        if (found != null) {
          resolvedWsId = found.workspaceId;
          resolvedStoreName = found.storeName;
          if (resolvedEmail.isEmpty && found.ownerEmail.isNotEmpty) {
            resolvedEmail = found.ownerEmail;
          }
        }
      }

      if (resolvedWsId.isEmpty && rawEmail.contains('@') && url.isNotEmpty) {
        final cloudRes = await AccountWorkspace.resolveWorkspaceInCloud(
          backendUrl: url,
          email: rawEmail,
          deviceId: devId,
          deviceFingerprint: hwFp,
        );
        if (cloudRes.found) {
          resolvedWsId = cloudRes.workspaceId;
          resolvedStoreName =
              '${cloudRes.meta?['storeName'] ?? cloudRes.meta?['store_name'] ?? ''}'
                  .trim();
        }
      }

      // بناء الكود البرمجي المشفر والموقع (nexora-ai-rpc) الذي لا يفهمه إلا الذكاء الاصطناعي ونظام الإدارة
      final aiPacket = AccountWorkspace.buildEncryptedAiRecoveryPacket(
        deviceId: devId,
        hardwareFingerprint: hwFp,
        phone: fullPhone,
        email: resolvedEmail,
        workspaceId: resolvedWsId,
        storeName: resolvedStoreName,
      );

      // (R-06) نُبلّغ بالنتيجة الحقيقية: لا ندّعي نجاحًا لم يحدث.
      RecoveryRequestOutcome? outcome;
      if (url.isNotEmpty) {
        outcome = await AccountWorkspace.submitPasswordResetSupportRequest(
          backendUrl: url,
          workspaceId: resolvedWsId,
          deviceId: devId,
          phone: fullPhone,
          email: resolvedEmail,
          storeName: resolvedStoreName,
          aiPacketCode: aiPacket,
        );
      }

      final launched = await _launchWhatsAppMessage(
        targetPhone: '967774190040',
        message: aiPacket,
      );

      if (!mounted) return;
      Sfx.success();
      final buffer = StringBuffer();
      if (launched) {
        buffer.write('أُرسل طلب استعادة موقّع إلى الدعم عبر الواتساب.\n');
      } else {
        buffer.write(
            'تعذّر فتح واتساب تلقائيًا — انسخ الحزمة أدناه وأرسلها إلى الدعم: 967774190040\n');
      }
      if (outcome != null && outcome.fullyDelivered) {
        buffer.write('وسُجّل الطلب رسميًا في السحابة برقم تذكرة ${outcome.ticketId}.\n');
      } else if (outcome != null && outcome.deliveredRemotely) {
        buffer.write('وسُجّل الطلب جزئيًا في السحابة (${outcome.ticketId}).\n');
      } else {
        buffer.write('لم يُسجَّل الطلب في السحابة — يكفي إرسال الحزمة عبر الواتساب.\n');
      }
      if (outcome != null && outcome.errors.isNotEmpty) {
        buffer.write('ملاحظات: ${outcome.errors.join(' · ')}');
      }
      setState(() {
        _busy = false;
        _generatedAiPacket = aiPacket;
        _successMsg = buffer.toString().trim();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = AppErrorMapper.toUserFriendlyMessage(e);
      });
      Sfx.error();
    }
  }

  /// إرسال رابط إعادة تعيين كلمة المرور الرسمي عبر البريد الإلكتروني (Firebase Auth).
  Future<void> _sendOfficialEmailResetLink() async {
    if (_busy) return;
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
      setState(() {
        _errorMsg = 'يرجى إدخال البريد الإلكتروني المسجل بشكل صحيح';
        _successMsg = null;
      });
      Sfx.error();
      return;
    }

    setState(() {
      _busy = true;
      _errorMsg = null;
      _successMsg = null;
    });

    try {
      await FirebaseAuthRest.sendPasswordResetEmail(email);
      if (!mounted) return;
      Sfx.success();
      setState(() {
        _busy = false;
        _successMsg =
            'تم إرسال رابط إعادة تعيين كلمة السر الرسمي إلى بريدك الإلكتروني ($email).\nافتح الرسالة الواردة في بريدك لتعيين كلمة السر الجديدة ثم عد لتسجيل الدخول.';
      });
    } on StateError catch (se) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (se.message.contains('EMAIL_NOT_FOUND')) {
          _errorMsg =
              'هذا البريد الإلكتروني غير مسجل بكلمة مرور في السحابة.\nيمكنك طلب رمز وكلمة مرور جديدة من الإدارة عبر خيار «طلب الرمز الجديد من الإدارة (واتساب)» بالأعلى.';
        } else {
          _errorMsg = 'يرجى التحقق من صحة البريد الإلكتروني المدخل.';
        }
      });
      Sfx.error();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = AppErrorMapper.toUserFriendlyMessage(e);
      });
      Sfx.error();
    }
  }

  @override
  Widget build(BuildContext context) {
    const waGreen = Color(0xFF16A34A);
    final primary = AppColors.primaryOf(context);
    final surface = Theme.of(context).colorScheme.surface;
    final divider = Theme.of(context).dividerColor;

    return Scaffold(
      appBar: AppBar(
        title: const Text('استعادة كلمة السر وحماية المنشأة'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: primary.withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.shield_rounded, color: primary, size: 26),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'نظام التحقق الأمني الصارم لاستعادة الحساب',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'لحماية بيانات منشأتك المالية من أي وصول غير مصرح به، لا يُسمح بتغيير كلمة السر محلياً بدون تحقق. '
                        'يتم إصدار الرمز وكلمة السر الجديدة حصرياً من الإدارة ومساعد الذكاء الاصطناعي بعد مطابقة رقم الهاتف وبصمة الجهاز، أو عبر رابط التحقق الرسمي في بريدك الإلكتروني.',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.55,
                          color: AppColors.text2Of(context),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // شريط التبويب بين مساري الاستعادة الموثقة
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: divider),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(9),
                          onTap: _busy
                              ? null
                              : () => setState(() {
                                    _mode = 'admin_whatsapp';
                                    _errorMsg = null;
                                    _successMsg = null;
                                  }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            decoration: BoxDecoration(
                              color: _mode == 'admin_whatsapp'
                                  ? waGreen
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.smart_toy_outlined,
                                  size: 17,
                                  color: _mode == 'admin_whatsapp'
                                      ? Colors.white
                                      : AppColors.text2Of(context),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'طلب الرمز من الإدارة (واتساب)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: _mode == 'admin_whatsapp'
                                        ? Colors.white
                                        : AppColors.text2Of(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(9),
                          onTap: _busy
                              ? null
                              : () => setState(() {
                                    _mode = 'email_link';
                                    _errorMsg = null;
                                    _successMsg = null;
                                  }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            decoration: BoxDecoration(
                              color: _mode == 'email_link'
                                  ? primary
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.mark_email_read_outlined,
                                  size: 17,
                                  color: _mode == 'email_link'
                                      ? Colors.white
                                      : AppColors.text2Of(context),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'رابط البريد الإلكتروني',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: _mode == 'email_link'
                                        ? Colors.white
                                        : AppColors.text2Of(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                if (_errorMsg != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      _errorMsg!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                if (_successMsg != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: waGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: waGreen.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      _successMsg!,
                      style: const TextStyle(
                        color: waGreen,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: divider),
                  ),
                  child: _mode == 'admin_whatsapp'
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'إرسال كود التحقق المشفر لاستلام كلمة السر من الإدارة',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'أدخل رقم الهاتف المسجل لمنشأتك (أو بريدك الإلكتروني). سيقوم التطبيق بتوليد حزمة برمجية مشفرة تتضمن بصمة جهازك وإرسالها لمحادثة الدعم الذكي في الواتساب للتحقق وإرسال الرمز الجديد إليك:',
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.5,
                                color: AppColors.text2Of(context),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 145,
                                  child: DropdownButtonFormField<String>(
                                    value: _countryDialCode,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                      labelText: 'مفتاح الدولة',
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 14),
                                    ),
                                    items: [
                                      for (final c in _dialCodes)
                                        DropdownMenuItem(
                                          value: c.$1,
                                          child: Text(
                                            c.$2,
                                            style:
                                                const TextStyle(fontSize: 12),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                    ],
                                    onChanged: _busy
                                        ? null
                                        : (v) {
                                            if (v != null) {
                                              setState(
                                                  () => _countryDialCode = v);
                                            }
                                          },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: _phoneCtrl,
                                    enabled: !_busy,
                                    keyboardType: TextInputType.phone,
                                    textDirection: TextDirection.ltr,
                                    decoration: const InputDecoration(
                                      labelText: 'رقم الهاتف المسجل للمنشأة *',
                                      hintText: '77xxxxxxx',
                                      prefixIcon:
                                          Icon(Icons.phone_iphone_rounded),
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _emailCtrl,
                              enabled: !_busy,
                              keyboardType: TextInputType.emailAddress,
                              textDirection: TextDirection.ltr,
                              decoration: const InputDecoration(
                                labelText: 'البريد الإلكتروني للمنشأة (اختياري)',
                                hintText: 'name@example.com',
                                prefixIcon: Icon(Icons.email_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                            if (_generatedAiPacket != null) ...[
                              const SizedBox(height: 14),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: divider),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.code_rounded,
                                            size: 16, color: waGreen),
                                        const SizedBox(width: 6),
                                        const Expanded(
                                          child: Text(
                                            'حزمة التحقق البرمجية المشفرة (NEXORA_AI_CORE_RPC)',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'نسخ الكود المشفر',
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(Icons.copy_rounded,
                                              size: 16),
                                          onPressed: () {
                                            Clipboard.setData(ClipboardData(
                                                text: _generatedAiPacket!));
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                    'تم نسخ كود التحقق المشفر ✓'),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                    Directionality(
                                      textDirection: TextDirection.ltr,
                                      child: SelectableText(
                                        _generatedAiPacket!,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 18),
                            SizedBox(
                              height: 48,
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                    backgroundColor: waGreen),
                                onPressed: _busy
                                    ? null
                                    : _requestRecoveryFromAdminSmartSupport,
                                icon: _busy
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: Colors.white,
                                        ),
                                      )
                                      : const Icon(Icons.send_to_mobile_rounded),
                                label: const Text(
                                  'إرسال كود التحقق المشفر للإدارة عبر الواتساب',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'إرسال رابط إعادة تعيين كلمة السر للبريد الإلكتروني',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'أدخل البريد الإلكتروني المسجل لمنشأتك ليصلك رابط رسمي آمن لإعادة تعيين كلمة السر:',
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.5,
                                color: AppColors.text2Of(context),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _emailCtrl,
                              enabled: !_busy,
                              keyboardType: TextInputType.emailAddress,
                              textDirection: TextDirection.ltr,
                              decoration: const InputDecoration(
                                labelText: 'البريد الإلكتروني المسجل *',
                                hintText: 'name@example.com',
                                prefixIcon: Icon(Icons.email_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 18),
                            SizedBox(
                              height: 48,
                              child: FilledButton.icon(
                                onPressed:
                                    _busy ? null : _sendOfficialEmailResetLink,
                                icon: _busy
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.mark_email_read_rounded),
                                label: const Text(
                                  'إرسال رابط إعادة تعيين كلمة السر للبريد',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
