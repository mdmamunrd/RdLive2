import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Repeating Islamic/Eastern arch pattern.
class ArchPatternPainter extends CustomPainter {
  final Color color;
  const ArchPatternPainter({this.color = const Color(0x40FFD778)});

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 44.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (double y = 0; y < size.height + cell; y += cell) {
      for (double x = 0; x < size.width + cell; x += cell) {
        final c = Offset(x + cell / 2, y + cell);
        canvas.drawArc(Rect.fromCircle(center: c, radius: 15), math.pi, math.pi, false, p);
        canvas.drawArc(Rect.fromCircle(center: c, radius: 8), math.pi, math.pi, false, p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ArchPatternPainter old) => old.color != color;
}

class ArchPattern extends StatelessWidget {
  final double opacity;
  const ArchPattern({super.key, this.opacity = 1});

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: const SizedBox.expand(child: CustomPaint(painter: ArchPatternPainter())),
        ),
      );
}

/// A hanging lantern that gently swings.
class Lantern extends StatefulWidget {
  final double width;
  final double stringLength;
  final Color color;
  final Duration period;
  final double phase; // 0..1 start offset

  const Lantern({
    super.key,
    this.width = 30,
    this.stringLength = 30,
    this.color = const Color(0xFFF59E0B),
    this.period = const Duration(seconds: 3),
    this.phase = 0,
  });

  @override
  State<Lantern> createState() => _LanternState();
}

class _LanternState extends State<Lantern> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
    value: widget.phase,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.stringLength + widget.width * 2.1;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Transform.rotate(
        angle: (Curves.easeInOut.transform(_c.value) - 0.5) * 0.14,
        alignment: Alignment.topCenter,
        child: child,
      ),
      child: CustomPaint(
        size: Size(widget.width, h),
        painter: _LanternPainter(widget.color, widget.stringLength),
      ),
    );
  }
}

class _LanternPainter extends CustomPainter {
  final Color color;
  final double stringLen;
  _LanternPainter(this.color, this.stringLen);

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final cx = w / 2;
    canvas.drawLine(Offset(cx, 0), Offset(cx, stringLen),
        Paint()..color = const Color(0xFFFCD34D)..strokeWidth = 1.6);

    final top = stringLen;
    final bodyH = w * 1.5;
    // cap
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(cx - w * .22, top - 2, w * .44, 6), const Radius.circular(3)),
      Paint()..color = const Color(0xFFB45309),
    );
    // body
    final body = Path()
      ..moveTo(cx - w * .28, top + 4)
      ..lineTo(cx + w * .28, top + 4)
      ..quadraticBezierTo(cx + w * .55, top + bodyH * .5, cx + w * .32, top + bodyH)
      ..lineTo(cx - w * .32, top + bodyH)
      ..quadraticBezierTo(cx - w * .55, top + bodyH * .5, cx - w * .28, top + 4)
      ..close();
    canvas.drawShadow(body, color, 8, true);
    canvas.drawPath(body, Paint()..color = color);
    // glowing core
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - w * .17, top + bodyH * .22, w * .34, bodyH * .55),
        Radius.circular(w * .17),
      ),
      Paint()..color = Colors.white.withValues(alpha: .55),
    );
    // base + tassel
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(cx - w * .22, top + bodyH, w * .44, 6), const Radius.circular(3)),
      Paint()..color = const Color(0xFFB45309),
    );
    final tp = Paint()..color = const Color(0xFFFCD34D)..strokeWidth = 2;
    for (final dx in [-.08, 0.0, .08]) {
      canvas.drawLine(Offset(cx + w * dx, top + bodyH + 6), Offset(cx + w * dx, top + bodyH + 6 + w * .35), tp);
    }
  }

  @override
  bool shouldRepaint(covariant _LanternPainter old) => old.color != color;
}

/// Small twinkling four-point star for backgrounds.
class Twinkle extends StatefulWidget {
  final double size;
  final Color color;
  final double phase;
  const Twinkle({super.key, this.size = 14, this.color = const Color(0xFFFEF08A), this.phase = 0});

  @override
  State<Twinkle> createState() => _TwinkleState();
}

class _TwinkleState extends State<Twinkle> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
    value: widget.phase,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: .25, end: 1.0).animate(_c),
        child: Icon(Icons.auto_awesome, size: widget.size, color: widget.color),
      );
}
