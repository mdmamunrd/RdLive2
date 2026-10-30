import 'package:flutter/material.dart';

import '../models/room_models.dart';
import '../theme/app_theme.dart';
import 'avatar_circle.dart';

/// Builds the live video for an occupied seat with the camera on.
/// Plug your Agora `AgoraVideoView` in here; a gradient placeholder is used otherwise.
typedef SeatVideoBuilder = Widget Function(BuildContext context, Seat seat);

/// One seat: empty / occupied / locked, with mic + camera status badges.
class SeatTile extends StatelessWidget {
  final Seat seat;

  /// Side length of the avatar / video square.
  final double size;
  final SeatMediaMode mediaMode;
  final bool isMine;
  final bool hasMyRequest;
  final SeatVideoBuilder? videoBuilder;
  final VoidCallback? onTap;

  const SeatTile({
    super.key,
    required this.seat,
    required this.size,
    this.mediaMode = SeatMediaMode.audio,
    this.isMine = false,
    this.hasMyRequest = false,
    this.videoBuilder,
    this.onTap,
  });

  bool get _video => mediaMode == SeatMediaMode.video;
  double get _radius => _video ? 18 : size / 2;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: _body(context)),
                Positioned(top: _video ? 6 : 0, left: _video ? 6 : 0, child: _NumberChip(seat.index + 1)),
                if (seat.isOccupied) ...[
                  Positioned(
                    right: _video ? 6 : 0,
                    bottom: _video ? 6 : 0,
                    child: _Badge(
                      icon: seat.micActive ? Icons.mic_rounded : Icons.mic_off_rounded,
                      color: seat.micActive ? AppColors.violet : Colors.redAccent,
                    ),
                  ),
                  if (_video || seat.cameraOn)
                    Positioned(
                      right: _video ? 6 : 0,
                      top: _video ? 6 : 0,
                      child: _Badge(
                        icon: seat.cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                        color: seat.cameraOn ? const Color(0xFF10B981) : Colors.grey,
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(width: size + 12, child: Center(child: _label())),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    switch (seat.status) {
      case SeatStatus.empty:
        return _placeholder(
          Icon(
            hasMyRequest ? Icons.hourglass_top_rounded : Icons.add_rounded,
            color: Colors.white70,
            size: size * .4,
          ),
          highlight: hasMyRequest,
        );
      case SeatStatus.locked:
        return _placeholder(
          Icon(Icons.lock_rounded, color: AppColors.gold.withValues(alpha: .9), size: size * .36),
        );
      case SeatStatus.occupied:
        return _occupied(context);
    }
  }

  Widget _placeholder(Widget icon, {bool highlight = false}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(
          color: highlight ? AppColors.gold : Colors.white24,
          width: highlight ? 2 : 1.2,
        ),
      ),
      child: Center(child: icon),
    );
  }

  Widget _occupied(BuildContext context) {
    final user = seat.user!;
    final active = seat.micActive;
    final ring = isMine ? AppColors.pink : (active ? AppColors.gold : Colors.white24);
    final glow = active
        ? [BoxShadow(color: AppColors.gold.withValues(alpha: .4), blurRadius: 12, spreadRadius: 1)]
        : null;

    if (!_video) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ring, width: 2.5),
          boxShadow: glow,
        ),
        padding: const EdgeInsets.all(3),
        child: AvatarCircle(name: user.name, url: user.avatarUrl, size: size - 11),
      );
    }
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(_radius),
      border: Border.all(color: ring, width: 2.5),
      boxShadow: glow,
    );

    final Widget feed;
    if (seat.cameraOn) {
      feed = videoBuilder != null ? videoBuilder!(context, seat) : _VideoPlaceholder(name: user.name);
    } else {
      feed = Container(
        color: Colors.black38,
        child: Center(child: AvatarCircle(name: user.name, url: user.avatarUrl, size: size * .5)),
      );
    }
    return Container(
      decoration: decoration,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius - 2.5),
        child: SizedBox.expand(child: feed),
      ),
    );
  }

  Widget _label() {
    const dim = TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w500);
    const bright = TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600);
    switch (seat.status) {
      case SeatStatus.empty:
        return Text(hasMyRequest ? 'Requested' : 'Join', style: dim);
      case SeatStatus.locked:
        return const Text('Locked', style: dim);
      case SeatStatus.occupied:
        final u = seat.user!;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (u.role == RoomRole.host)
              const Icon(Icons.workspace_premium_rounded, color: AppColors.gold, size: 14)
            else if (u.role == RoomRole.moderator)
              const Icon(Icons.shield_rounded, color: Color(0xFF7DD3FC), size: 13),
            if (u.role != RoomRole.audience) const SizedBox(width: 2),
            Text(u.flagEmoji, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                isMine ? 'You' : u.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: bright,
              ),
            ),
          ],
        );
    }
  }
}

class _NumberChip extends StatelessWidget {
  final int n;
  const _NumberChip(this.n);

  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .45), shape: BoxShape.circle),
        child: Text('$n',
            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
      );
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _Badge({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: Icon(icon, color: Colors.white, size: 12),
      );
}

class _VideoPlaceholder extends StatelessWidget {
  final String name;
  const _VideoPlaceholder({required this.name});

  @override
  Widget build(BuildContext context) {
    final seed = name.codeUnits.fold<int>(0, (a, b) => a + b);
    final hue = (seed * 47) % 360;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue.toDouble(), .6, .45).toColor(),
            HSLColor.fromAHSL(1, ((hue + 50) % 360).toDouble(), .6, .25).toColor(),
          ],
        ),
      ),
      child: const Center(child: Icon(Icons.videocam_rounded, color: Colors.white38, size: 34)),
    );
  }
}
