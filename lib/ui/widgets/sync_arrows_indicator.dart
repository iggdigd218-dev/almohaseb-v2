import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sfx.dart';
import '../../data/providers.dart';
import '../../data/sync/sync_activity.dart';
import '../../data/sync/sync_diagnostics.dart';
import '../dialogs/sync_resolution_dialog.dart';
import '../widgets.dart' show showSnack;

/// مؤشر المزامنة السحابية في الشريط العلوي:
/// - دائرة مكونة من قوسين متناظرين برأسين متعاكسين في الموقع يتبعان بعضهما
///   في مسار دائري واحد مع عقارب الساعة وبدون أي إطار أو خلفية.
/// - ألوان فاتحة وزاهية ومبهجة تعبّر عن حالات المزامنة بوضوح.
/// - حركة دوران سريعة وسلسة لمدة ثانية واحدة (1s) عند الضغط لفحص المزامنة،
///   وحركة دوران مترافقة مع نبضة (Scale pulse 1.0 → 1.22 → 1.0) عند استلام
///   عملية سحابية أو نبضة مزامنة فعالة.
class SyncArrowsIndicator extends ConsumerStatefulWidget {
  const SyncArrowsIndicator({super.key});

  @override
  ConsumerState<SyncArrowsIndicator> createState() =>
      _SyncArrowsIndicatorState();
}

class _SyncArrowsIndicatorState extends ConsumerState<SyncArrowsIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  StreamSubscription<int>? _busSub;
  DateTime? _lastObservedPullAt;
  DateTime? _lastObservedPushAt;
  bool _wasSyncing = false;
  bool _pulseActive = false;
  int _turnsPerRun = 2;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _busSub = SyncActivityBus.instance.stream.listen((_) {
      if (!mounted) return;
      _triggerPulseSpin();
    });
  }

  @override
  void dispose() {
    _busSub?.cancel();
    _animCtrl.dispose();
    super.dispose();
  }

  /// تشغيل دوران سريع لمدة ثانية واحدة عند الضغط اليدوي على الأيقونة.
  void _triggerTapSpin() {
    _pulseActive = false;
    _turnsPerRun = 2;
    _animCtrl.duration = const Duration(milliseconds: 1000);
    _animCtrl.forward(from: 0);
  }

  /// تشغيل دوران سريع مترافق مع نبضة انبساط وانقباض (1.0 -> 1.22 -> 1.0)
  /// عند استلام حركة جديدة من السحابة أو بدء نبضة مزامنة فعالة.
  void _triggerPulseSpin() {
    setState(() {
      _pulseActive = true;
      _turnsPerRun = 1;
    });
    _animCtrl.duration = const Duration(milliseconds: 900);
    _animCtrl.forward(from: 0);
  }

  void _checkStateTransitions(SyncDiagnosticsSnapshot s) {
    final nowSyncing = s.pushing || s.pulling;
    final newPull = s.lastPullAt != null &&
        s.lastPullAt != _lastObservedPullAt &&
        s.lastPullApplied > 0;
    final newPush = s.lastPushAt != null &&
        s.lastPushAt != _lastObservedPushAt &&
        s.lastPushOk;

    if ((nowSyncing && !_wasSyncing) || newPull || newPush) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_animCtrl.isAnimating) {
          _triggerPulseSpin();
        }
      });
    }
    _wasSyncing = nowSyncing;
    _lastObservedPullAt = s.lastPullAt;
    _lastObservedPushAt = s.lastPushAt;
  }

  @override
  Widget build(BuildContext context) {
    final modeAsync = ref.watch(workspaceModeProvider);
    final mode = modeAsync.value ?? modeAsync.asData?.value;
    final st = ref.watch(settingsProvider).value ?? const <String, String>{};
    final googleLinked = ref.watch(googleLinkedProvider).value ?? false;
    final wsId = (st['sync.workspaceId'] ?? '').trim();
    final cloudProv = (st['cloudWorkspaceProvisioned'] ?? '0').trim();
    final isLocalIndividual = (st['account.type'] ?? '') == 'individual' ||
        cloudProv != '1' ||
        wsId == 'default' ||
        ((st['account.email'] ?? st['email'] ?? '').trim().isEmpty &&
            !googleLinked);
    if (mode == 'standalone' ||
        isLocalIndividual ||
        (mode == null && !modeAsync.isLoading)) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<SyncDiagnosticsSnapshot>(
      valueListenable: SyncDiagnostics.instance.notifier,
      builder: (context, s, _) {
        _checkStateTransitions(s);
        final hydrated = s.lastPullAt != null || s.lastPullApplied > 0;

        // درجات لونية فاتحة، زاهية، ومبهجة وواضحة للعين
        final Color upColor;
        if (s.uploadFaulted) {
          upColor = const Color(0xFFFF5252);
        } else if (s.pushing) {
          upColor = const Color(0xFF00E676);
        } else if (hydrated &&
            (s.lastPushOk || (!s.uploadFaulted && s.failedCount == 0))) {
          upColor = const Color(0xFF10B981);
        } else {
          upColor = const Color(0xFFFFB300);
        }

        final Color downColor;
        if (s.downloadFaulted) {
          downColor = const Color(0xFFFF5252);
        } else if (s.pulling) {
          downColor = const Color(0xFF38BDF8);
        } else if (hydrated && (s.lastPullOk || !s.downloadFaulted)) {
          downColor = const Color(0xFF0EA5E9);
        } else {
          downColor = const Color(0xFF38BDF8);
        }

        final tooltipMsg = s.catalogMismatch
            ? (s.catalogMismatchDetails ??
                '⚠️ تحذير: عدم تطابق في الحسابات أو الأصناف أو الأقسام بين الأجهزة')
            : (!hydrated
                ? 'بانتظار استكمال الجلب الأولي للبيانات...'
                : 'مؤشر المزامنة اللحظية');

        return Tooltip(
          message: tooltipMsg,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () async {
              Sfx.tap();
              _triggerTapSpin();
              try {
                await ref.read(syncEngineProvider).reconcileAndSyncNow();
              } catch (_) {}
              if (!context.mounted) return;
              final diag = SyncDiagnostics.instance.snapshot;
              final diagHydrated =
                  diag.lastPullAt != null || diag.lastPullApplied > 0;
              final isNetworkFaultOnly =
                  (diag.lastPushFault == SyncFaultSource.network ||
                          diag.lastPullFault == SyncFaultSource.network) &&
                      diag.lastLocalizedError == null &&
                      !diag.catalogMismatch &&
                      diag.failedCount == 0;
              if (diag.catalogMismatch ||
                  (diag.uploadFaulted && !isNetworkFaultOnly) ||
                  (diag.downloadFaulted && !isNetworkFaultOnly) ||
                  diag.failedCount > 0 ||
                  diag.lastLocalizedError != null) {
                SyncResolutionDialog.show(context);
              } else if (diag.pushing || diag.pulling || !diagHydrated) {
                showSnack(context, 'المزامنة السحابية جارية الآن...');
              } else if (isNetworkFaultOnly) {
                showSnack(
                  context,
                  'تعذر الوصول للخادم السحابي مؤقتاً — ستتم المزامنة تلقائياً',
                );
              } else {
                showSnack(context, 'المزامنة السحابية متصلة ومستقرة ✅');
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: AnimatedBuilder(
                animation: _animCtrl,
                builder: (context, child) {
                  final t = Curves.easeInOutCubic.transform(_animCtrl.value);
                  final angle = t * 2 * math.pi * _turnsPerRun;
                  double scale = 1.0;
                  if (_pulseActive && _animCtrl.isAnimating) {
                    // نبضة ناعمة: 1.0 -> 1.22 -> 1.0
                    scale = 1.0 + 0.22 * math.sin(_animCtrl.value * math.pi);
                  }
                  return Transform.scale(
                    scale: scale,
                    child: Transform.rotate(
                      angle: angle,
                      child: child,
                    ),
                  );
                },
                child: _ThinSyncCircle(
                  upColor: upColor,
                  downColor: downColor,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// دائرة المزامنة النحيفة: قوسان متناظران برأسين متعاكسين يتبعان بعضهما في
/// مسار دائري واحد مع عقارب الساعة بدون إطار ولا خلفية.
class _ThinSyncCircle extends StatelessWidget {
  final Color upColor;
  final Color downColor;

  const _ThinSyncCircle({
    required this.upColor,
    required this.downColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CustomPaint(
        painter: _ThinSyncCirclePainter(
          upColor: upColor,
          downColor: downColor,
        ),
      ),
    );
  }
}

class _ThinSyncCirclePainter extends CustomPainter {
  final Color upColor;
  final Color downColor;

  _ThinSyncCirclePainter({
    required this.upColor,
    required this.downColor,
  });

  static const double _kStroke = 1.5;
  // كل قوس يغطي حوالي 154 درجة (~2.68 راديان) مع فجوة متناظرة صغيرة بينهما
  static const double _kSweep = 2.68;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) / 2) - 1.8;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // القوس العلوي: يبدأ من الجهة اليسرى (-pi + 0.23) ويمتد مع عقارب الساعة
    // لينتهي برأس سهم في الجهة اليمنى العلوية (-0.23).
    const upStart = -math.pi + 0.23;
    _drawClockwiseArcArrow(
      canvas,
      rect: rect,
      center: center,
      radius: radius,
      start: upStart,
      sweep: _kSweep,
      color: upColor,
    );

    // القوس السفلي المقابل: يبدأ من الجهة اليمنى السفلية (+0.23) ويمتد مع
    // عقارب الساعة لينتهي برأس سهم في الجهة اليسرى السفلية (pi - 0.23).
    const downStart = 0.23;
    _drawClockwiseArcArrow(
      canvas,
      rect: rect,
      center: center,
      radius: radius,
      start: downStart,
      sweep: _kSweep,
      color: downColor,
    );
  }

  void _drawClockwiseArcArrow(
    Canvas canvas, {
    required Rect rect,
    required Offset center,
    required double radius,
    required double start,
    required double sweep,
    required Color color,
  }) {
    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kStroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawArc(rect, start, sweep, false, arcPaint);

    // رأس السهم في نهاية القوس باتجاه الدوران (مع عقارب الساعة)
    final tipAngle = start + sweep;
    final tip = Offset(
      center.dx + radius * math.cos(tipAngle),
      center.dy + radius * math.sin(tipAngle),
    );
    final backAngle = tipAngle - (math.pi / 2) - 0.14;
    const headLen = 3.6;
    const wingSpread = 0.56;

    final p1 = Offset(
      tip.dx + headLen * math.cos(backAngle - wingSpread),
      tip.dy + headLen * math.sin(backAngle - wingSpread),
    );
    final p2 = Offset(
      tip.dx + headLen * math.cos(backAngle + wingSpread),
      tip.dy + headLen * math.sin(backAngle + wingSpread),
    );

    final headPath = Path()
      ..moveTo(p1.dx, p1.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(p2.dx, p2.dy);
    canvas.drawPath(headPath, arcPaint);
  }

  @override
  bool shouldRepaint(covariant _ThinSyncCirclePainter old) =>
      old.upColor != upColor || old.downColor != downColor;
}
