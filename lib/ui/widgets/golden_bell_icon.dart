import 'package:flutter/material.dart';

/// أيقونة الإشعارات الذهبية الموحدة 🔔 (أعلى يسار الشاشة).
/// تعرض رمز الجرس 🔔 بشكل واضح ومتناسق مع الثيم العالمي للنظام المحاسبي.
class GoldenBellIcon extends StatelessWidget {
  final double size;
  final bool showSparkle;
  final bool hasUnread;

  const GoldenBellIcon({
    super.key,
    this.size = 24.0,
    this.showSparkle = true,
    this.hasUnread = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _BellGlowPainter(
              showSparkle: showSparkle || hasUnread,
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '🔔',
              style: TextStyle(
                fontSize: size * 0.85,
                height: 1.0,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _BellGlowPainter extends CustomPainter {
  final bool showSparkle;

  const _BellGlowPainter({required this.showSparkle});

  @override
  void paint(Canvas canvas, Size size) {
    if (!showSparkle) return;
    final paint = Paint()
      ..color = const Color(0xFFF59E0B).withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width * 0.48,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _BellGlowPainter oldDelegate) =>
      oldDelegate.showSparkle != showSparkle;
}
