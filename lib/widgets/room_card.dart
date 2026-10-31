import 'package:flutter/material.dart';

import '../models/live_room.dart';
import 'net_image.dart';

const _gradients = <List<Color>>[
  [Color(0xFFF472B6), Color(0xFF7C3AED)],
  [Color(0xFF10B981), Color(0xFF065F46)],
  [Color(0xFFF59E0B), Color(0xFFB91C1C)],
  [Color(0xFF334155), Color(0xFF0EA5E9)],
  [Color(0xFF8B5CF6), Color(0xFFEC4899)],
  [Color(0xFFEF4444), Color(0xFFF59E0B)],
];
const _avatarFallback = [Color(0xFFFBBF24), Color(0xFF34D399), Color(0xFF60A5FA)];

class RoomCard extends StatelessWidget {
  final LiveRoom room;
  final int index; // used only to vary placeholder colours
  final VoidCallback? onTap;

  const RoomCard({super.key, required this.room, this.index = 0, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetImage(url: room.coverUrl, placeholder: _gradients[index % _gradients.length]),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.center,
                        colors: [Color(0x73000000), Colors.transparent],
                      ),
                    ),
                  ),
                  const Positioned(top: 8, left: 8, child: _LiveChip()),
                  if (room.badge != null) Positioned(top: 8, right: 8, child: _Badge(room.badge!)),
                  Positioned(left: 8, bottom: 8, child: _AudienceStack(urls: room.audienceAvatars)),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Row(
              children: [
                Text(room.flagEmoji, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    room.hostName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveChip extends StatelessWidget {
  const _LiveChip();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .35), borderRadius: BorderRadius.circular(20)),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, size: 7, color: Colors.redAccent),
          SizedBox(width: 4),
          Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge(this.text);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF3B82F6),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.star_rounded, size: 13, color: Color(0xFFFDE047)),
          const SizedBox(width: 3),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _AudienceStack extends StatelessWidget {
  final List<String> urls;
  const _AudienceStack({required this.urls});

  @override
  Widget build(BuildContext context) {
    const size = 24.0;
    const overlap = 16.0;
    final n = urls.isEmpty ? 3 : urls.length.clamp(0, 3);
    return SizedBox(
      width: size + overlap * (n - 1),
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < n; i++)
            Positioned(
              left: i * overlap,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                child: ClipOval(
                  child: urls.isEmpty
                      ? ColoredBox(color: _avatarFallback[i])
                      : NetImage(url: urls[i], placeholder: [_avatarFallback[i], _avatarFallback[i]]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
