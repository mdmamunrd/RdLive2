import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Promotional banner. Pass [imageUrl] later to replace the artwork via API.
class HeroBanner extends StatelessWidget {
  final String eyebrow;
  final String titleTop;
  final String titleBottom;
  final VoidCallback? onTap;

  const HeroBanner({
    super.key,
    this.eyebrow = 'WEEKLY EVENT',
    this.titleTop = 'ROOM',
    this.titleBottom = 'TOP 1',
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 144,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            colors: [Color(0xFF5B21B6), Color(0xFFA21CAF), Color(0xFFF59E0B)],
          ),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              right: -24,
              top: -24,
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.gold.withValues(alpha: .25)),
              ),
            ),
            Positioned(
              right: 14,
              bottom: 2,
              child: SizedBox(
                width: 118,
                height: 118,
                child: CustomPaint(painter: _CrownCharacterPainter()),
              ),
            ),
            Positioned(
              left: 20,
              top: 0,
              bottom: 0,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(eyebrow,
                      style: const TextStyle(
                        color: Color(0xFFFEF08A),
                        fontSize: 11,
                        letterSpacing: 2.6,
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(height: 2),
                  Text(titleTop,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                        shadows: [Shadow(color: Color(0x40000000), offset: Offset(0, 2))],
                      )),
                  Text(titleBottom,
                      style: const TextStyle(
                        color: AppColors.gold,
                        fontSize: 32,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                        shadows: [Shadow(color: Color(0x40000000), offset: Offset(0, 2))],
                      )),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('Join now ›',
                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CrownCharacterPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 120, size.height / 120);
    Paint f(Color c) => Paint()..color = c;

    canvas.drawOval(Rect.fromCenter(center: const Offset(60, 108), width: 68, height: 12), f(const Color(0x33000000)));
    canvas.drawCircle(const Offset(60, 74), 26, f(const Color(0xFFFDE68A)));
    canvas.drawCircle(const Offset(50, 72), 3.2, f(const Color(0xFF3B0764)));
    canvas.drawCircle(const Offset(70, 72), 3.2, f(const Color(0xFF3B0764)));
    canvas.drawCircle(const Offset(44, 80), 4, f(const Color(0x99FB7185)));
    canvas.drawCircle(const Offset(76, 80), 4, f(const Color(0x99FB7185)));
    canvas.drawPath(
      Path()
        ..moveTo(51, 83)
        ..quadraticBezierTo(60, 91, 69, 83),
      Paint()
        ..color = const Color(0xFF3B0764)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );

    final crown = Path()
      ..moveTo(34, 52)
      ..lineTo(42, 26)
      ..lineTo(54, 42)
      ..lineTo(60, 20)
      ..lineTo(66, 42)
      ..lineTo(78, 26)
      ..lineTo(86, 52)
      ..close();
    canvas.drawPath(crown, f(AppColors.gold));
    canvas.drawPath(
      crown,
      Paint()
        ..color = AppColors.lanternGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(const Offset(42, 26), 3.5, f(AppColors.pink));
    canvas.drawCircle(const Offset(60, 20), 3.5, f(const Color(0xFF60A5FA)));
    canvas.drawCircle(const Offset(78, 26), 3.5, f(const Color(0xFF34D399)));
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(35, 50, 50, 6), const Radius.circular(3)),
      f(AppColors.lanternGold),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
