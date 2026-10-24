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

  /// المتابعة بدون حساب Google — عمل محلي كامل (المحلية أولاً).
  Future<void> _startLocal() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      await completeOnboarding(
        repo,
        storeName: _name,
        currencyCode: _currency,
        phone: _phone,
        activity: _activity,
      );
      await repo.setSetting('account.type', 'individual');
      await repo.restoreManagerOwnership(syncToCloud: false);
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      final wsId = repo.requireWorkspaceId;
      if (_name.trim().isNotEmpty &&
          _name.trim() != 'متجري' &&
          _name.trim() != 'منشأتي' &&
          wsId.isNotEmpty &&
          wsId != 'default') {
        await AccountWorkspace.saveWorkspaceToLocalRegistry(
          WorkspaceInfo(
            workspaceId: wsId,
            storeName: _name.trim(),
            defaultCurrency: _currency,
            role: 'owner',
            isCurrent: true,
          ),
        );
      }
      _invalidateAllSessionProviders();
      await _finishAndNavigate();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// المسار الموحّد والمنظّم لتسجيل الدخول أو إنشاء حساب عبر Google:
  ///   • إذا كان `isLoginFlow == true` (تسجيل الدخول لحساب مسجل مسبقاً):
  ///     يبحث عن المنشأة المرتبطة بالبريد في السحابة وفي الجهاز ويفتحها فوراً.
  ///     وإن لم توجد منشأة مسجلة بهذا البريد، يخيّر المستخدم بين إنشاء منشأة جديدة له أو اختيار بريد آخر.
  ///   • إذا كان `isLoginFlow == false` (إنشاء حساب ومنشأة جديدة):
  ///     يتحقق أولاً ما إذا كان للبريد منشأة مسجلة مسبقاً؛ فإن وُجدت يخيّر المستخدم بين
  ///     فتح منشأته السابقة أو تأسيس منشأة إضافية معزولة على نفس الجهاز. وإن لم توجد، ينقله مباشرة لشاشة تأسيس المنشأة.
  Future<void> _handleGoogleAuthFlow({required bool isLoginFlow}) async {
    if (_busy) return;
    Sfx.click();
    setState(() => _busy = true);

    final repo = ref.read(repoProvider);
    final db = await repo.database;
    if (!mounted) {
      setState(() => _busy = false);
      return;
    }
    final auth = GoogleAuthService(db);

    String statusText = 'جاري فتح نافذة اختيار حساب Google...';
    StateSetter? updateDialog;
    bool dialogOpen = true;
    bool userCancelled = false;

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dctx) => PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            dialogOpen = false;
            userCancelled = true;
          }
        },
        child: StatefulBuilder(
          builder: (ctx, setDialogState) {
            updateDialog = setDialogState;
            return Center(
              child: Card(
                elevation: 12,
                margin: const EdgeInsets.symmetric(horizontal: 24),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: BorderSide(
                    color:
                        Theme.of(context).primaryColor.withValues(alpha: 0.2),
                  ),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        statusText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14.5,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: () {
                          userCancelled = true;
                          dialogOpen = false;
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: const Text('إلغاء'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    void closeProgressDialog() {
      if (dialogOpen && mounted) {
        dialogOpen = false;
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
      }
    }

    try {
      final r = await auth.signIn(forceAccountPicker: true).timeout(
            const Duration(seconds: 45),
            onTimeout: () => const GoogleAuthResult.fail(
                'انتهت مهلة استجابة Google — تأكد من الاتصال وأعد المحاولة.'),
          );

      if (userCancelled || !mounted) return;

      final gu = r.user;
      if (gu == null) {
        closeProgressDialog();
        Sfx.error();
        if (mounted && r.error != 'تم إلغاء تسجيل الدخول') {
          showSnack(
            context,
            r.error ?? 'تعذّر تسجيل الدخول بحساب Google',
            error: true,
          );
        }
        return;
      }

      statusText =
          'تم التحقق من البريد: ${gu.email}\nجاري توثيق الهوية السحابية وفحص المنشآت المسجلة...';
      updateDialog?.call(() {});

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

      FirebaseAuthRest.primeAccountInMemory(account);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);

      // فحص المنشآت المسجلة لهذا البريد محلياً وسحابياً
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

      final hasExistingWorkspace =
          cloudRes.found || localMatches.isNotEmpty;
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
        closeProgressDialog();
        if (!mounted) return;
        final decision = await showDialog<String>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.domain_verification_rounded,
                    color: Color(0xFF0284C7)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'حساب مسجل مسبقاً',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            content: Text(
              'البريد الإلكتروني (${account!.email}) مرتبط بمنشأة مسجلة مسبقاً'
              '${existingStoreName.isNotEmpty ? ' باسم «$existingStoreName»' : ''}.\n\n'
              'ماذا ترغب أن تفعل؟',
              style: const TextStyle(fontSize: 13.5, height: 1.6),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop('cancel'),
                child: const Text('إلغاء'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(dctx).pop('create_additional'),
                icon: const Icon(Icons.add_business_rounded, size: 18),
                label: const Text('تأسيس منشأة جديدة مستقلة'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(dctx).pop('restore'),
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('فتح واسترجاع منشأتي السابقة'),
              ),
            ],
          ),
        );

        if (decision == 'cancel' || decision == null || !mounted) return;
        if (decision == 'create_additional') {
          final resolvedAcc = account;
          Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(
              builder: (_) => CreateWorkspaceScreen(
                ownerEmail: resolvedAcc.email,
                ownerUid: resolvedAcc.uid,
                ownerDisplayName: resolvedAcc.displayName,
                isAdditionalWorkspace: true,
              ),
            ),
          );
          return;
        }
        // إذا اختار 'restore' نكمل عملية الاسترجاع أدناه
      }

      if (hasExistingWorkspace && existingWsId.isNotEmpty) {
        statusText =
            'تم العثور على منشأتك${existingStoreName.isNotEmpty ? ' «$existingStoreName»' : ''}\nجاري استرجاع البيانات وفتح قاعدة البيانات...';
        updateDialog?.call(() {});

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

          closeProgressDialog();
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

      // لم يُعثر على منشأة سابقة لهذا البريد
      closeProgressDialog();
      if (!mounted) return;

      if (isLoginFlow) {
        final createNew = await showDialog<bool>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.info_outline_rounded, color: Colors.orange),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'لا توجد منشأة مسجلة بهذا البريد',
                    style:
                        TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            content: Text(
              'لم يتم العثور على أي منشأة مسجلة مسبقاً للبريد الإلكتروني:\n'
              '${account!.email}\n\n'
              'هل ترغب في إنشاء حساب وتأسيس منشأة جديدة بهذا البريد الآن، أم اختيار بريد إلكتروني آخر؟',
              style: const TextStyle(fontSize: 13.5, height: 1.6),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(false),
                child: const Text('اختيار بريد آخر'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(dctx).pop(true),
                icon: const Icon(Icons.add_business_rounded, size: 18),
                label: const Text('إنشاء منشأة جديدة بهذا البريد'),
              ),
            ],
          ),
        );
        if (createNew != true || !mounted) return;
      }

      // عزل وتوجيه مباشر لشاشة إعداد المنشأة الجديدة (CreateWorkspaceScreen)
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
      if (!mounted) return;
      final resolvedAcc = account;
      Navigator.of(context, rootNavigator: true).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CreateWorkspaceScreen(
            ownerEmail: resolvedAcc.email,
            ownerUid: resolvedAcc.uid,
            ownerDisplayName: resolvedAcc.displayName,
          ),
        ),
      );
    } catch (e) {
      closeProgressDialog();
      if (mounted) {
        showSnack(context, 'حدث خطأ أثناء الاتصال: $e', error: true);
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
        title: const Text('⚠️ حذف كامل من الجهاز والسحابة'),
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
          content: Text('✅ تم الحذف الكامل — الجهاز والسحابة نظيفان'),
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
    final wide = MediaQuery.sizeOf(context).width > 720;
    final primary = AppColors.primaryOf(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
              children: [
                // ---------- الترويسة ----------
                Center(
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(Icons.shopping_cart_rounded,
                        size: 40, color: primary),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'مرحباً بك في سجل الحسابات',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'اختر طريقة الدخول أو إنشاء حساب لمنشأتك ببيانات معزولة وآمنة',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.text2Of(context),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 22),

                // ---------- 0) المنشآت المحفوظة على هذا الجهاز (إن وجدت) ----------
                if (!_loadingWorkspaces && _deviceWorkspaces.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: primary.withValues(alpha: 0.28),
                        width: 1.4,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.domain_rounded,
                                color: primary, size: 22),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'المنشآت المحفوظة على هذا الجهاز (دخول سريع)',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${_deviceWorkspaces.length} منشأة',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'اضغط على أي منشأة لفتح قاعدة بياناتها المعزولة مباشرة دون تداخل مع المنشآت الأخرى:',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.text2Of(context),
                          ),
                        ),
                        const SizedBox(height: 12),
                        for (final ws in _deviceWorkspaces)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: _busy
                                    ? null
                                    : () => _openSavedDeviceWorkspace(ws),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: Theme.of(context).dividerColor,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        backgroundColor:
                                            primary.withValues(alpha: 0.14),
                                        foregroundColor: primary,
                                        child: const Icon(
                                            Icons.storefront_rounded,
                                            size: 20),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              ws.storeName,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 14,
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
                                      FilledButton.tonalIcon(
                                        onPressed: _busy
                                            ? null
                                            : () =>
                                                _openSavedDeviceWorkspace(ws),
                                        icon: const Icon(Icons.login_rounded,
                                            size: 17),
                                        label: const Text('دخول'),
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
                  const SizedBox(height: 20),
                ],

                // ---------- 1 & 2) تسجيل الدخول أو إنشاء حساب ومنشأة جديدة ----------
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _signInExistingCard()),
                      const SizedBox(width: 14),
                      Expanded(child: _createNewWorkspaceCard()),
                    ],
                  )
                else ...[
                  _signInExistingCard(),
                  const SizedBox(height: 14),
                  _createNewWorkspaceCard(),
                ],
                const SizedBox(height: 14),

                // ---------- 3 & 4) انضمام كعضو أو استخدام محلي مستقل ----------
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _joinMemberCard()),
                      const SizedBox(width: 14),
                      Expanded(child: _localStandaloneCard()),
                    ],
                  )
                else ...[
                  _joinMemberCard(),
                  const SizedBox(height: 14),
                  _localStandaloneCard(),
                ],

                const SizedBox(height: 18),
                Center(
                  child: TextButton.icon(
                    onPressed: _busy ? null : _purgeEverything,
                    icon: const Icon(Icons.delete_forever_outlined,
                        size: 17, color: Colors.red),
                    label: const Text(
                      'حذف كامل من الجهاز والسحابة',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.red,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _signInExistingCard() => _ModeCard(
        selected: _choice == 'login_existing',
        icon: Icons.verified_user_outlined,
        bigIcon: Icons.login_rounded,
        color: const Color(0xFF0284C7),
        title: 'تسجيل الدخول لحساب مسجل مسبقاً',
        badge: 'استرجاع منشأتك',
        description:
            'لديك حساب ومنشأة مسجلة سابقاً؟ سجّل الدخول عبر بريد Google '
            'للتعرف على حسابك واسترجاع منشأتك وبياناتك المحاسبية فوراً.',
        onTap: () => _handleGoogleAuthFlow(isLoginFlow: true),
      );

  Widget _createNewWorkspaceCard() => _ModeCard(
        selected: _choice == 'create_new',
        icon: Icons.domain_add_rounded,
        bigIcon: Icons.add_business_rounded,
        color: const Color(0xFF16A34A),
        title: 'إنشاء حساب ومنشأة جديدة',
        badge: 'تأسيس منشأة',
        description:
            'تأسيس منشأة جديدة بقاعدة بيانات SQLite مستقلة ومعزولة، مع ربطها '
            'ببريدك الإلكتروني للمزامنة السحابية وإدارة الأجهزة.',
        onTap: () => _handleGoogleAuthFlow(isLoginFlow: false),
      );

  Widget _joinMemberCard() => _ModeCard(
        selected: _choice == 'join_member',
        icon: Icons.group_add_rounded,
        bigIcon: Icons.qr_code_scanner_rounded,
        color: const Color(0xFF7C3AED),
        title: 'الانضمام لمنشأة قائمة (عضو / موظف)',
        badge: 'ربط بالرمز أو QR',
        description:
            'هل أنت محاسب أو كاشير في منشأة قائمة؟ انضم مباشرة عبر مسح باركود '
            'QR أو إدخال رمز الدعوة المكون من 6 أرقام من جهاز المدير.',
        onTap: _openJoinMemberDialog,
      );

  Widget _localStandaloneCard() => _ModeCard(
        selected: _choice == 'personal',
        icon: Icons.person_outline_rounded,
        bigIcon: Icons.storefront_rounded,
        color: const Color(0xFFD97706),
        title: 'استخدام محلي مستقل (بدون بريد)',
        badge: 'على هذا الجهاز فقط',
        description:
            'دفتر حسابات محلي يعمل على هذا الجهاز فقط بدون بريد إلكتروني '
            'وبدون مزامنة سحابية (يمكنك ربطه لاحقاً في أي وقت).',
        onTap: _openLocalStandaloneDialog,
      );
}

/// بطاقة اختيار منظمة وعالية الوضوح.
class _ModeCard extends StatefulWidget {
  final bool selected;
  final IconData icon;
  final IconData bigIcon;
  final Color color;
  final String title;
  final String badge;
  final String description;
  final VoidCallback onTap;
  const _ModeCard({
    required this.selected,
    required this.icon,
    required this.bigIcon,
    required this.color,
    required this.title,
    required this.badge,
    required this.description,
    required this.onTap,
  });

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final c = widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        decoration: BoxDecoration(
          color: sel
              ? c.withValues(alpha: .08)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: sel ? c : Theme.of(context).dividerColor,
            width: sel ? 2.4 : 1.4,
          ),
          boxShadow: (_hover || sel)
              ? [
                  BoxShadow(
                    color: c.withValues(alpha: .18),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(widget.bigIcon, color: c, size: 27),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.withValues(alpha: .35)),
                        ),
                        child: Text(
                          widget.badge,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: c,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(widget.icon, size: 18, color: c),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios_rounded,
                          size: 15, color: c.withValues(alpha: 0.8)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.description,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.55,
                      color: AppColors.text2Of(context),
                    ),
                  ),
                ],
              ),
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
