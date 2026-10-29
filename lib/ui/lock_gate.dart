import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/security.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'onboarding_screen.dart';

/// بوابة القفل — تعترض التطبيق قبل عرضه إن كانت البصمة مفعّلة.
///
/// تعيد المحاولة تلقائيًا عند العودة من الخلفية إذا فُعّل «القفل التلقائي».
class LockGate extends ConsumerStatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate>
    with WidgetsBindingObserver {
  bool _checking = true;
  bool _locked = false;
  bool _expelled = false;
  bool _autoLock = false;
  bool _prompting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _init() async {
    var enabled = false;
    var expelled = false;
    try {
      // نستخدم نفس الـ Repo المُهيّأ في main.dart عبر Riverpod — لا ننشئ اتصالاً جديدًا.
      final repo = ref.read(repoProvider);
      if (await repo.amIExpelled()) {
        await repo.resetToStandaloneAfterExpulsion();
        expelled = true;
      } else if (await repo.isWorkspaceExpelledOrRevoked()) {
        expelled = true;
      } else {
        final st = await repo.settings().timeout(const Duration(seconds: 3));
        enabled = st['biometric'] == '1';
        _autoLock = st['autoLock'] == '1';
      }
    } catch (_) {
      enabled = false;
    }
    if (!mounted) return;
    if (expelled) {
      setState(() {
        _checking = false;
        _expelled = true;
        _locked = true;
      });
      return;
    }
    if (!enabled) {
      setState(() {
        _checking = false;
        _locked = false;
      });
      return;
    }
    setState(() {
      _checking = false;
      _locked = true;
    });
    await _unlock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _autoLock && !_locked) {
      setState(() => _locked = true);
    }
  }

  Future<void> _unlock() async {
    if (_prompting) return;
    _prompting = true;
    final ok = await Security.authenticate();
    _prompting = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_expelled) {
      return Scaffold(
        backgroundColor: AppColors.bgOf(context),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.block, size: 56, color: Colors.redAccent),
                const SizedBox(height: 16),
                const Text(
                  'تم إلغاء الوصول / ارتباطك ملغى من قِبل المنشأة',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (_) => const OnboardingScreen(
                          initialNotice:
                              'تم إلغاء الوصول / ارتباطك ملغى من قِبل المنشأة',
                        ),
                      ),
                      (_) => false,
                    );
                  },
                  icon: const Icon(Icons.exit_to_app),
                  label: const Text('العودة لشاشة البداية'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_locked) return widget.child;

    return Scaffold(
      backgroundColor: AppColors.bgOf(context),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.asset(
                  'assets/images/logo.png',
                  width: 112,
                  height: 112,
                ),
              ),
              const SizedBox(height: 18),
              Icon(
                Icons.fingerprint,
                size: 46,
                color: AppColors.primaryOf(context),
              ),
              const SizedBox(height: 12),
              Text(
                'المحاسب',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primaryOf(context),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'التطبيق مقفل — أكّد هويتك بالبصمة للمتابعة',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  color: AppColors.text2Of(context),
                ),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _unlock,
                icon: const Icon(Icons.lock_open_outlined),
                label: const Text('فتح القفل'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
