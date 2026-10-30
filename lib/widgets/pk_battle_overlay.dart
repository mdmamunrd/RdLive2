import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/pk_models.dart';
import '../services/pk_controller.dart';
import '../theme/app_theme.dart';
import 'avatar_circle.dart';

class PkColors {
  static const red = Color(0xFFEF4444);
  static const redDark = Color(0xFF7F1D1D);
  static const blue = Color(0xFF3B82F6);
  static const blueDark = Color(0xFF1E3A8A);
}

/// Split-screen PK battle: two host streams, animated score bar, countdown
/// and a victory overlay. Rebuilds when [controller] changes.
class PkBattleOverlay extends StatelessWidget {
  final PkController controller;

  /// Host sees Start / End / Rematch buttons.
  final bool isHost;

  /// Shows "+500" test buttons (mock data only).
  final bool showDemoControls;
  final VoidCallback? onClose;

  const PkBattleOverlay({
    super.key,
    required this.controller,
    this.isHost = false,
    this.showDemoControls = false,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final finished = controller.status == PkStatus.finished;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .28),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TopBar(controller: controller, onClose: onClose),
                  SizedBox(
                    height: 210,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Row(children: [
                          Expanded(child: _HostStream(controller: controller, side: PkSide.a)),
                          Expanded(child: _HostStream(controller: controller, side: PkSide.b)),
                        ]),
                        const _VsBadge(),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                    child: PkScoreBar(controller: controller),
                  ),
                  _Controls(controller: controller, isHost: isHost, showDemoControls: showDemoControls),
                  const SizedBox(height: 8),
                ],
              ),
              if (finished)
                Positioned.fill(
                  child: PkVictoryOverlay(
                    controller: controller,
                    isHost: isHost,
                    onRematch: controller.rematch,
                    onClose: onClose,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar: status + countdown
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  final PkController controller;
  final VoidCallback? onClose;
  const _TopBar({required this.controller, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Align(alignment: Alignment.centerLeft, child: _StatusChip(status: controller.status)),
          ),
          const Spacer(),
          PkTimerPill(controller: controller),
          const Spacer(),
          SizedBox(
            width: 84,
            child: Align(
              alignment: Alignment.centerRight,
              child: onClose == null
                  ? null
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                      onPressed: onClose,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final PkStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    late final String text;
    late final Color color;
    switch (status) {
      case PkStatus.ready:
        text = 'READY';
        color = AppColors.gold;
      case PkStatus.running:
        text = 'PK LIVE';
        color = PkColors.red;
      case PkStatus.finished:
        text = 'ENDED';
        color = Colors.grey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: .2), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (status == PkStatus.running) ...[
          const Icon(Icons.circle, size: 7, color: PkColors.red),
          const SizedBox(width: 4),
        ],
        Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

/// mm:ss countdown. Turns red for the last 10 seconds.
class PkTimerPill extends StatelessWidget {
  final PkController controller;
  const PkTimerPill({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final low = controller.status == PkStatus.running && controller.remaining <= 10;
    final color = low ? PkColors.red : Colors.white;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: low ? PkColors.red : Colors.white24),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.timer_outlined, size: 16, color: color),
        const SizedBox(width: 5),
        Text(controller.clock,
            style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Host stream containers
// ---------------------------------------------------------------------------

class _HostStream extends StatelessWidget {
  final PkController controller;
  final PkSide side;
  const _HostStream({required this.controller, required this.side});

  @override
  Widget build(BuildContext context) {
    final isA = side == PkSide.a;
    final host = isA ? controller.hostA : controller.hostB;
    final accent = isA ? PkColors.red : PkColors.blue;
    final dark = isA ? PkColors.redDark : PkColors.blueDark;
    final finished = controller.status == PkStatus.finished;
    final lost = finished && !controller.isDraw && controller.winner != side;
    final gift = isA ? controller.lastGiftA : controller.lastGiftB;

    return AnimatedOpacity(
      opacity: lost ? .55 : 1,
      duration: const Duration(milliseconds: 300),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [dark, Colors.black87],
          ),
          border: Border.all(color: accent.withValues(alpha: .7), width: 1.5),
        ),
        child: Stack(
          children: [
            // TODO: replace with the Agora video view of this host
            Center(
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: accent, width: 2.5)),
                child: AvatarCircle(name: host.name, url: host.avatarUrl, size: 76),
              ),
            ),
            Positioned(
              top: 8,
              left: isA ? 8 : null,
              right: isA ? null : 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(8)),
                child: Text(isA ? 'RED' : 'BLUE',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
              ),
            ),
            Positioned(
              left: 6,
              right: 6,
              bottom: 40,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: gift == null
                      ? const SizedBox(key: ValueKey<int>(-1), height: 22)
                      : _GiftPop(key: ValueKey<int>(gift.id), event: gift, color: accent),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(host.flagEmoji, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(host.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GiftPop extends StatelessWidget {
  final PkGiftEvent event;
  final Color color;
  const _GiftPop({super.key, required this.event, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: .9), borderRadius: BorderRadius.circular(12)),
        child: Text('${event.senderName} +${formatScore(event.points)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
      );
}

class _VsBadge extends StatelessWidget {
  const _VsBadge();

  @override
  Widget build(BuildContext context) => Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.gold, AppColors.lanternGold],
          ),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8)],
        ),
        child: const Text('VS',
            style: TextStyle(color: AppColors.deepPurple, fontSize: 16, fontWeight: FontWeight.w900)),
      );
}

// ---------------------------------------------------------------------------
// Animated score bar (red vs blue)
// ---------------------------------------------------------------------------

class PkScoreBar extends StatelessWidget {
  final PkController controller;
  const PkScoreBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.5, end: controller.ratioA),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, ratio, _) {
              final redW = w * ratio;
              return ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: Stack(
                  children: [
                    Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(colors: [PkColors.blueDark, PkColors.blue]),
                      ),
                    ),
                    Container(
                      width: redW,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(colors: [PkColors.red, PkColors.redDark]),
                      ),
                    ),
                    Positioned(
                      left: redW - 1.5,
                      top: 0,
                      bottom: 0,
                      child: Container(width: 3, color: Colors.white),
                    ),
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _Score(value: controller.scoreA),
                            _Score(value: controller.scoreB),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Score extends StatelessWidget {
  final int value;
  const _Score({required this.value});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: 0, end: value),
      duration: const Duration(milliseconds: 600),
      builder: (context, v, _) => Text(
        formatScore(v),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w900,
          shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Host buttons (+ mock gift buttons)
// ---------------------------------------------------------------------------

class _Controls extends StatelessWidget {
  final PkController controller;
  final bool isHost;
  final bool showDemoControls;
  const _Controls({required this.controller, required this.isHost, required this.showDemoControls});

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    final buttons = <Widget>[
      if (isHost && status == PkStatus.ready)
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.pink, shape: const StadiumBorder()),
          onPressed: controller.start,
          icon: const Icon(Icons.flash_on_rounded),
          label: Text('Start PK (${controller.clock})'),
        ),
      if (isHost && status == PkStatus.running)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white54),
            shape: const StadiumBorder(),
          ),
          onPressed: controller.finish,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('End PK'),
        ),
      if (showDemoControls && status == PkStatus.running) ...[
        TextButton(
          style: TextButton.styleFrom(foregroundColor: PkColors.red),
          onPressed: () => controller.addScore(PkSide.a, 500, sender: 'You'),
          child: const Text('+500 Red'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: PkColors.blue),
          onPressed: () => controller.addScore(PkSide.b, 500, sender: 'You'),
          child: const Text('+500 Blue'),
        ),
      ],
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(alignment: WrapAlignment.center, spacing: 8, children: buttons),
    );
  }
}

// ---------------------------------------------------------------------------
// Victory overlay + confetti
// ---------------------------------------------------------------------------

class PkVictoryOverlay extends StatelessWidget {
  final PkController controller;
  final bool isHost;
  final VoidCallback? onRematch;
  final VoidCallback? onClose;

  const PkVictoryOverlay({
    super.key,
    required this.controller,
    required this.isHost,
    this.onRematch,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final draw = controller.isDraw;
    final winner = controller.winner;
    final host = winner == PkSide.b ? controller.hostB : controller.hostA;
    final color = draw ? AppColors.gold : (winner == PkSide.a ? PkColors.red : PkColors.blue);

    return Container(
      color: Colors.black.withValues(alpha: .74),
      child: Stack(
        children: [
          if (!draw) const Positioned.fill(child: ConfettiBurst()),
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: .3, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.elasticOut,
              builder: (context, v, child) => Transform.scale(scale: v, child: child),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(draw ? Icons.compare_arrows_rounded : Icons.emoji_events_rounded,
                      size: 70, color: AppColors.gold),
                  const SizedBox(height: 4),
                  Text(draw ? 'DRAW' : 'VICTORY',
                      style: const TextStyle(
                          color: AppColors.gold,
                          fontSize: 14,
                          letterSpacing: 4,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(draw ? 'Both hosts tied' : host.name,
                      style: TextStyle(color: color, fontSize: 28, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 6),
                  Text('${formatScore(controller.scoreA)}  :  ${formatScore(controller.scoreB)}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    if (isHost && onRematch != null) ...[
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: AppColors.pink, shape: const StadiumBorder()),
                        onPressed: onRematch,
                        icon: const Icon(Icons.replay_rounded),
                        label: const Text('Rematch'),
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (onClose != null)
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                          shape: const StadiumBorder(),
                        ),
                        onPressed: onClose,
                        child: const Text('Close'),
                      ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ConfettiBurst extends StatefulWidget {
  const ConfettiBurst({super.key});

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _Particle {
  final double angle, speed, size, spin;
  final Color color;
  const _Particle(this.angle, this.speed, this.size, this.spin, this.color);
}

class _ConfettiBurstState extends State<ConfettiBurst> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..forward();
  late final List<_Particle> _ps = _make();

  List<_Particle> _make() {
    final r = math.Random(7);
    const colors = [AppColors.gold, AppColors.pink, PkColors.red, PkColors.blue, Color(0xFF34D399)];
    return List.generate(
      44,
      (i) => _Particle(
        -math.pi * (0.1 + 0.8 * r.nextDouble()), // fan upwards
        140 + r.nextDouble() * 260,
        5 + r.nextDouble() * 6,
        r.nextDouble() * 6,
        colors[i % colors.length],
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(painter: _ConfettiPainter(_c, _ps), size: Size.infinite),
      );
}

class _ConfettiPainter extends CustomPainter {
  final Animation<double> anim;
  final List<_Particle> ps;
  _ConfettiPainter(this.anim, this.ps) : super(repaint: anim);

  @override
  void paint(Canvas canvas, Size size) {
    final t = anim.value;
    final origin = Offset(size.width / 2, size.height * .55);
    final alpha = (1 - t).clamp(0.0, 1.0).toDouble();
    for (final p in ps) {
      final pos = origin +
          Offset(math.cos(p.angle) * p.speed * t, math.sin(p.angle) * p.speed * t + 380 * t * t);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.spin * t * 6);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * .6),
        Paint()..color = p.color.withValues(alpha: alpha),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.ps != ps;
}
