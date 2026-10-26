// شاشة البداية: شعار متحرك يظهر لحظة فتح التطبيق ثم ينتقل للتطبيق.
// عند أول تشغيل (قاعدة فارغة بلا إعداد سابق) تُعرض شاشة الإعداد الأول.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/providers.dart';
import 'create_workspace_screen.dart';
import 'home_shell.dart';
import 'lock_gate.dart';
import 'onboarding_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..forward();
    _scale = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.7, curve: Curves.easeOutBack),
    );
    _fade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.35, 1, curve: Curves.easeIn),
    );
    _go();
  }

  Future<void> _go() async {
    Widget nextTarget = const LockGate(child: HomeShell());
    await Future.wait([
      Future.delayed(const Duration(milliseconds: 1400)),
      () async {
        try {
          final container = ProviderScope.containerOf(context, listen: false);
          final repo = container.read(repoProvider);

          // (حماية ضد المدير الشبح بعد الطرد) فحص الطرد أو الإلغاء قبل أي ترقية محلية
          if (await repo.amIExpelled()) {
            await repo.resetToStandaloneAfterExpulsion();
            nextTarget = const OnboardingScreen(
              initialNotice: 'تم إلغاء الوصول / ارتباطك ملغى من قِبل المنشأة',
            );
            return;
          }
          if (await repo.isWorkspaceExpelledOrRevoked()) {
            nextTarget = const OnboardingScreen(
              initialNotice: 'تم إلغاء الوصول / ارتباطك ملغى من قِبل المنشأة',
            );
            return;
          }

          final st = await repo.settings();
          final mode = await repo.workspaceMode();

          // العضو المقترن أو أي حساب به بيانات سابقة لا يُقذف إلى شاشة الإعداد أو البداية أبداً
          final isMember = mode == 'member';
          final hasCompletedOnboarding = st['has_completed_onboarding'] == '1' || st['onboardingCompleted'] == '1';
          final localAccounts = await repo.accounts(includeArchived: true, includeDeleted: true);
          final hasData = localAccounts.isNotEmpty;

          if (!isMember && !hasCompletedOnboarding && !hasData) {
            final email =
                (st['account.email'] ?? st['email'] ?? '').trim();
            final uid = (st['account.uid'] ?? '').trim();
            final name = (st['account.name'] ?? '').trim();
            if (email.isNotEmpty) {
              nextTarget = CreateWorkspaceScreen(
                ownerEmail: email,
                ownerUid: uid,
                ownerDisplayName: name,
              );
            } else {
              nextTarget = const OnboardingScreen();
            }
            return;
          }
          if (mode != 'member') {
            await repo
                .restoreManagerOwnership()
                .timeout(const Duration(seconds: 2));
            await repo
                .checkAndAutoPromoteManager()
                .timeout(const Duration(seconds: 2));
            await repo
                .ensureSelfPermissionRow(roleCode: 'admin')
                .timeout(const Duration(seconds: 2));
          }
          await repo
              .setSetting(kOnboardingDoneKey, '1')
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
      }(),
    ]);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => nextTarget,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryOf(context),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: Tween(begin: 0.5, end: 1.0).animate(_scale),
              child: FadeTransition(
                opacity: _fade,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset(
                      'assets/images/logo.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            FadeTransition(
              opacity: _fade,
              child: const Text(
                'المحاسب',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 10),
            FadeTransition(
              opacity: _fade,
              child: const Text(
                'سجل المبيعات والديون',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
            const SizedBox(height: 34),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
