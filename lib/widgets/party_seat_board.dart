import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/room_models.dart';
import '../services/room_controller.dart';
import '../theme/app_theme.dart';
import 'avatar_circle.dart';

/// Audio party seats: host seat + VIP seat on top, then the numbered guest
/// seats (1..9) in rows of three. Seat 0 of the controller is the host.
class PartySeatBoard extends StatelessWidget {
  final RoomController controller;
  final ValueChanged<Seat> onSeatTap;
  final VoidCallback? onVipTap;

  const PartySeatBoard({
    super.key,
    required this.controller,
    required this.onSeatTap,
    this.onVipTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final seats = controller.seats;
        final host = seats.isNotEmpty ? seats.first : null;
        final guests = seats.length > 1 ? seats.sublist(1) : <Seat>[];
        final request = controller.myRequest;
        final firstEmpty = seats.indexWhere((s) => s.isEmpty);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: LayoutBuilder(
            builder: (context, c) {
              final cell = c.maxWidth / 3;
              final size = math.min(cell * .62, 76.0);
              final hostSize = math.min(cell * .8, 92.0);

              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Center(
                          child: host == null
                              ? const SizedBox()
                              : _HostSeat(
                                  seat: host,
                                  size: hostSize,
                                  isMine: host.user?.id == RoomController.meId,
                                  onTap: () => onSeatTap(host),
                                ),
                        ),
                      ),
                      const _HeartLink(),
                      Expanded(
                        child: Center(child: _VipSeat(size: hostSize, onTap: onVipTap)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  for (var r = 0; r < guests.length; r += 3)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        children: [
                          for (var i = r; i < r + 3; i++)
                            Expanded(
                              child: i < guests.length
                                  ? Center(
                                      child: _Chair(
                                        seat: guests[i],
                                        size: size,
                                        isMine: guests[i].user?.id == RoomController.meId,
                                        hasMyRequest: request != null &&
                                            (request.seatIndex == null
                                                ? (guests[i].isEmpty && guests[i].index == firstEmpty)
                                                : request.seatIndex == guests[i].index),
                                        onTap: () => onSeatTap(guests[i]),
                                      ),
                                    )
                                  : const SizedBox(),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _HostSeat extends StatelessWidget {
  final Seat seat;
  final double size;
  final bool isMine;
  final VoidCallback onTap;

  const _HostSeat({
    required this.seat,
    required this.size,
    required this.isMine,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final user = seat.user;
    final active = seat.micActive;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: .25),
              border: Border.all(color: isMine ? AppColors.pink : AppColors.gold, width: 3),
              boxShadow: active
                  ? [BoxShadow(color: AppColors.gold.withValues(alpha: .45), blurRadius: 14, spreadRadius: 1)]
                  : null,
            ),
            child: user == null
                ? const Icon(Icons.event_seat_rounded, color: AppColors.pink)
                : AvatarCircle(name: user.name, url: user.avatarUrl, size: size - 12),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: size + 24,
            child: Text(
              user == null ? 'Host' : (isMine ? 'You' : user.name),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('💎', style: TextStyle(fontSize: 12)),
              SizedBox(width: 4),
              Text('0', style: TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeartLink extends StatelessWidget {
  const _HeartLink();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      child: Center(
        child: Container(
          width: 38,
          height: 26,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .3),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: Colors.white24),
          ),
          child: const Icon(Icons.favorite_rounded, color: AppColors.pink, size: 15),
        ),
      ),
    );
  }
}

class _VipSeat extends StatelessWidget {
  final double size;
  final VoidCallback? onTap;

  const _VipSeat({required this.size, this.onTap});

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
              alignment: Alignment.center,
              children: [
                Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: .4),
                    border: Border.all(color: AppColors.gold, width: 3),
                  ),
                  child: const Icon(Icons.event_seat_rounded, color: AppColors.gold, size: 38),
                ),
                Positioned(
                  top: -8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B0A4E),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.gold),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.workspace_premium_rounded, color: AppColors.gold, size: 12),
                        SizedBox(width: 2),
                        Text('VIP',
                            style: TextStyle(
                                color: AppColors.gold, fontSize: 11, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const Text('Book VIP',
              style: TextStyle(color: AppColors.gold, fontSize: 14, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _Chair extends StatelessWidget {
  final Seat seat;
  final double size;
  final bool isMine;
  final bool hasMyRequest;
  final VoidCallback onTap;

  const _Chair({
    required this.seat,
    required this.size,
    required this.isMine,
    required this.hasMyRequest,
    required this.onTap,
  });

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
                Positioned.fill(child: _body()),
                if (seat.isOccupied) ...[
                  Positioned(top: -2, left: -2, child: _NumChip(seat.index)),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: _MicBadge(active: seat.micActive),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          _label(),
        ],
      ),
    );
  }

  Widget _body() {
    switch (seat.status) {
      case SeatStatus.empty:
        return _circle(
          Icon(
            hasMyRequest ? Icons.hourglass_top_rounded : Icons.event_seat_rounded,
            color: hasMyRequest ? AppColors.gold : AppColors.pink,
            size: size * .46,
          ),
          border: hasMyRequest ? AppColors.gold : Colors.white30,
          width: hasMyRequest ? 2 : 1.2,
        );
      case SeatStatus.locked:
        return _circle(
          Icon(Icons.lock_rounded, color: AppColors.gold.withValues(alpha: .9), size: size * .38),
          border: Colors.white30,
          width: 1.2,
        );
      case SeatStatus.occupied:
        final user = seat.user!;
        final active = seat.micActive;
        final ring = isMine ? AppColors.pink : (active ? AppColors.gold : Colors.white24);
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: 2.5),
            boxShadow: active
                ? [BoxShadow(color: AppColors.gold.withValues(alpha: .4), blurRadius: 12, spreadRadius: 1)]
                : null,
          ),
          child: AvatarCircle(name: user.name, url: user.avatarUrl, size: size - 11),
        );
    }
  }

  Widget _circle(Widget icon, {required Color border, required double width}) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: .25),
        border: Border.all(color: border, width: width),
      ),
      child: Center(child: icon),
    );
  }

  Widget _label() {
    const dim = TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w700);
    const bright = TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600);
    if (!seat.isOccupied) {
      return Text('${seat.index}', style: dim);
    }
    final u = seat.user!;
    return SizedBox(
      width: size + 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (u.role == RoomRole.moderator) ...[
            const Icon(Icons.shield_rounded, color: Color(0xFF7DD3FC), size: 13),
            const SizedBox(width: 2),
          ],
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
      ),
    );
  }
}

class _NumChip extends StatelessWidget {
  final int n;
  const _NumChip(this.n);

  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .55), shape: BoxShape.circle),
        child: Text('$n',
            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
      );
}

class _MicBadge extends StatelessWidget {
  final bool active;
  const _MicBadge({required this.active});

  @override
  Widget build(BuildContext context) => Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: active ? AppColors.violet : Colors.redAccent,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: Icon(active ? Icons.mic_rounded : Icons.mic_off_rounded, color: Colors.white, size: 12),
      );
}
