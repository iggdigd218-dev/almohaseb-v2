// شاشة البداية: شعار متحرك يظهر لحظة فتح التطبيق ثم ينتقل للتطبيق.
// عند أول تشغيل (قاعدة فارغة بلا إعداد سابق) تُعرض شاشة الإعداد الأول.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      duration: const Duration(milliseconds: 700),
    )..forward();
    _scale = CurvedAnimation(
      parent: _c,
      curve: Curves.easeOutCubic,
    );
    _fade = CurvedAnimation(
      parent: _c,
      curve: Curves.easeOut,
    );
    _go();
  }

  Future<void> _go() async {
    Widget nextTarget = const LockGate(child: HomeShell());
    await Future.wait([
      Future.delayed(const Duration(milliseconds: 750)),
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
          final hasCompletedOnboarding =
              st['has_completed_onboarding'] == '1' ||
                  st['onboardingCompleted'] == '1';
          final localAccounts = await repo.accounts(
              includeArchived: true, includeDeleted: true);
          final hasData = localAccounts.isNotEmpty;

          if (!isMember && !hasCompletedOnboarding && !hasData) {
            final email = (st['account.email'] ?? st['email'] ?? '').trim();
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
            unawaited(() async {
              try {
                await repo
                    .restoreManagerOwnership()
                    .timeout(const Duration(seconds: 2));
                await repo
                    .checkAndAutoPromoteManager()
                    .timeout(const Duration(seconds: 2));
                await repo
                    .ensureSelfPermissionRow(roleCode: 'admin')
                    .timeout(const Duration(seconds: 2));
              } catch (_) {}
            }());
          }
          unawaited(
            repo
                .setSetting(kOnboardingDoneKey, '1')
                .timeout(const Duration(seconds: 2))
                .catchError((_) {}),
          );
        } catch (_) {}
      }(),
    ]);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
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
      backgroundColor: const Color(0xFFE0F2FE),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFF0F9FF),
              Color(0xFFE0F2FE),
              Color(0xFFBAE6FD),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: Tween(begin: 0.88, end: 1.0).animate(_scale),
                child: FadeTransition(
                  opacity: _fade,
                  child: Container(
                    width: 118,
                    height: 118,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0284C7).withValues(alpha: 0.16),
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
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              FadeTransition(
                opacity: _fade,
                child: const Text(
                  'المحاسب بلاس',
                  style: TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FadeTransition(
                opacity: _fade,
                child: const Text(
                  'نظام محاسبي متكامل',
                  style: TextStyle(
                    color: Color(0xFF0369A1),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 30),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.3,
                  color: Color(0xFF0284C7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
