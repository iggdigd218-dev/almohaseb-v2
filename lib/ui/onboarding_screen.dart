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

import '../core/accounting.dart';
import '../core/cloud_config.dart';
import '../core/factory_reset.dart';
import '../core/security.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
import 'account_section.dart' show provisionCloudAfterSignIn;
import 'create_workspace_screen.dart';
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
                onPressed: () => Navigator.of(dctx).pop(),
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

  Future<void> _loadSavedDeviceWorkspaces() async {
    try {
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
    final st = await repo.settings();
    final url = effectiveBackendUrl(st['cloudBackendUrl']);

    final localMatches = await AccountWorkspace.findLocalWorkspacesOnDevice(
      filterEmail: account.email,
    );
    CloudWorkspaceResolution cloudRes =
        const CloudWorkspaceResolution(workspaceId: '');
    if (url.isNotEmpty) {
      try {
        cloudRes = await AccountWorkspace.resolveWorkspaceInCloud(
          backendUrl: url,
          email: account.email,
          uid: account.uid,
        ).timeout(
          const Duration(seconds: 15),
          onTimeout: () => const CloudWorkspaceResolution(workspaceId: ''),
        );
      } catch (_) {}
    }

    final hasExistingWorkspace = cloudRes.found || localMatches.isNotEmpty;
    final existingWsId = cloudRes.found
        ? cloudRes.workspaceId
        : (localMatches.isNotEmpty ? localMatches.first.workspaceId : '');
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
      if (url.isNotEmpty) {
        try {
          final outcome = await AccountWorkspace.linkAccountOnly(
            repo,
            backendUrl: url,
            account: account,
            forceIsolateNewUser: true,
          ).timeout(const Duration(seconds: 35));
          restored = outcome == AccountLinkOutcome.switched ||
              outcome == AccountLinkOutcome.migrated;
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
        await repo.setSetting('account.type', 'enterprise');
        await repo.setSetting(kOnboardingDoneKey, '1');
        await repo.setSetting('onboardingCompleted', '1');
        await FirebaseAuthRest.saveSession(repo, account);
        if (account.email.trim().isNotEmpty) {
          await repo.setSetting('account.email', account.email.trim());
          await repo.setSetting('email', account.email.trim());
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

    // في حال عدم وجود حساب/منشأة مسجلة: توجيه تلقائي مباشر لشاشة إنشاء حساب جديد مع تعبئة البريد مسبقاً
    if (url.isNotEmpty) {
      try {
        await AccountWorkspace.linkAccountOnly(
          repo,
          backendUrl: url,
          account: account,
          forceIsolateNewUser: true,
        ).timeout(const Duration(seconds: 20));
      } catch (_) {}
    }
    await FirebaseAuthRest.saveSession(repo, account);
    if (!mounted) return;
    if (isLoginFlow) {
      showSnack(
        context,
        'لا توجد منشأة مسجلة لـ ${account.email} — تم تحويلك لإنشاء حساب جديد مع تعبئة بريدك تلقائياً',
      );
    }
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

  /// تسجيل الدخول عبر البريد الإلكتروني وكلمة المرور (مع التحويل التلقائي لإنشاء حساب جديد عند عدم وجود الحساب).
  Future<void> _handleEmailLogin({bool isRegisterButton = false}) async {
    if (_busy) return;
    final email = _emailCtrl.text.trim().toLowerCase();
    final password = _passwordCtrl.text;

    if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
      setState(() => _authError =
          'يرجى إدخال البريد الإلكتروني وكلمة المرور أو التسجيل عبر حساب Google');
      Sfx.error();
      return;
    }
    if (password.trim().length < 6) {
      setState(
          () => _authError = 'يرجى إدخال كلمة المرور (6 أحرف على الأقل)');
      Sfx.error();
      return;
    }

    Sfx.click();
    setState(() {
      _busy = true;
      _authError = null;
    });

    try {
      final account = isRegisterButton
          ? await FirebaseAuthRest.signUpWithEmailPassword(
              email: email,
              password: password,
            )
          : await FirebaseAuthRest.signInWithEmailPassword(
              email: email,
              password: password,
            );

      await _resolveWorkspaceOrRedirectToRegister(
        account: account,
        isLoginFlow: !isRegisterButton,
      );
    } on StateError catch (se) {
      final msg = se.message;
      // Auto-Redirect Non-Existent Users (USER_NOT_FOUND) to Create New Account with email pre-filled
      if (msg.contains('USER_NOT_FOUND') ||
          msg.contains('INVALID_CREDENTIALS_OR_NOT_FOUND')) {
        FirebaseAccount fallbackAcc;
        try {
          fallbackAcc = await FirebaseAuthRest.signUpWithEmailPassword(
            email: email,
            password: password,
          );
        } catch (_) {
          fallbackAcc = FirebaseAccount(
            uid: 'email:${AccountWorkspace.emailToKey(email)}',
            email: email,
          );
        }
        await _resolveWorkspaceOrRedirectToRegister(
          account: fallbackAcc,
          isLoginFlow: true,
        );
        return;
      }
      if (!mounted) return;
      setState(() => _authError = msg);
      Sfx.error();
    } catch (e) {
      if (!mounted) return;
      setState(() => _authError = 'حدث خطأ أثناء الاتصال: $e');
      Sfx.error();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
        setState(() => _authError = 'حدث خطأ أثناء الاتصال: $e');
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

                // ---------- بطاقة تسجيل الدخول وإنشاء الحساب ----------
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
                      const SizedBox(height: 16),
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
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 46,
                        child: OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _handleGoogleAuthFlow(isLoginFlow: true),
                          child: const Text(
                            'المتابعة عبر حساب Google',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Divider(height: 1),
                      ),
                      SizedBox(
                        height: 46,
                        child: FilledButton.tonal(
                          onPressed: _busy
                              ? null
                              : () =>
                                  _handleEmailLogin(isRegisterButton: true),
                          child: const Text(
                            'إنشاء حساب جديد وتأسيس منشأة',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ---------- خيارات الربط كعضو أو العمل المحلي ----------
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: OutlinedButton(
                          onPressed: _busy ? null : _openJoinMemberDialog,
                          child: const Text(
                            'انضمام كعضو (رمز / QR)',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: OutlinedButton(
                          onPressed: _busy ? null : _openLocalStandaloneDialog,
                          child: const Text(
                            'استخدام محلي مستقل',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
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
