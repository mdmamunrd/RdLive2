import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/room_models.dart';
import '../services/room_controller.dart';
import 'seat_tile.dart';

/// Responsive 4-seat (2x2) or 8-seat (4x2) grid. Rebuilds when [controller] changes.
class SeatGrid extends StatelessWidget {
  final RoomController controller;
  final ValueChanged<Seat> onSeatTap;
  final SeatMediaMode mediaMode;
  final SeatVideoBuilder? videoBuilder;
  final EdgeInsets padding;

  const SeatGrid({
    super.key,
    required this.controller,
    required this.onSeatTap,
    this.mediaMode = SeatMediaMode.audio,
    this.videoBuilder,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final layout = controller.layout;
        final seats = controller.seats;
        const myId = RoomController.meId;
        final myRequestSeat = controller.myRequest?.seatIndex;

        return Padding(
          padding: padding,
          child: LayoutBuilder(
            builder: (context, c) {
              const gap = 10.0;
              final cols = layout.columns;
              // floor so cols * cell + gaps never exceeds the width (no accidental wrap)
              final cell = ((c.maxWidth - gap * (cols - 1)) / cols).floorToDouble();
              final media = mediaMode == SeatMediaMode.video
                  ? cell
                  : math.min(cell * .72, layout == SeatLayout.four ? 116.0 : 76.0);

              return Wrap(
                alignment: WrapAlignment.center,
                spacing: gap,
                runSpacing: 14,
                children: [
                  for (final seat in seats)
                    SizedBox(
                      width: cell,
                      child: Center(
                        child: SeatTile(
                          seat: seat,
                          size: media,
                          mediaMode: mediaMode,
                          isMine: seat.user?.id == myId,
                          hasMyRequest: controller.myRequest != null &&
                              (myRequestSeat == null
                                  ? seat.isEmpty && seat.index == _firstEmpty(seats)
                                  : myRequestSeat == seat.index),
                          videoBuilder: videoBuilder,
                          onTap: () => onSeatTap(seat),
                        ),
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

  static int _firstEmpty(List<Seat> seats) => seats.indexWhere((s) => s.isEmpty);
}
