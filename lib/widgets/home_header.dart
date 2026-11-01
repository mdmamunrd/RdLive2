import 'package:flutter/material.dart';

import '../services/room_api.dart';
import '../theme/app_theme.dart';
import 'festive_decor.dart';

/// Festive header: arch pattern, hanging lanterns, tabs, game + search icons.
class HomeHeader extends StatelessWidget {
  final RoomTab selected;
  final ValueChanged<RoomTab> onTabChanged;
  final VoidCallback? onGames;
  final VoidCallback? onSearch;

  const HomeHeader({
    super.key,
    required this.selected,
    required this.onTabChanged,
    this.onGames,
    this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.header1, AppColors.violet],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: ArchPattern(opacity: .8)),
          const Positioned(left: 14, top: 0, child: Lantern(width: 22, stringLength: 14)),
          Positioned(
            left: MediaQuery.of(context).size.width * .48,
            top: 0,
            child: const Lantern(width: 18, stringLength: 8, color: AppColors.pink, phase: .5),
          ),
          const Positioned(right: 96, top: 0, child: Lantern(width: 16, stringLength: 4, color: Color(0xFFFBBF24), phase: .25)),
          Padding(
            padding: EdgeInsets.fromLTRB(16, top + 44, 12, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _Tab('Discover', RoomTab.discover, selected, onTabChanged),
                const SizedBox(width: 20),
                _Tab('New', RoomTab.newest, selected, onTabChanged),
                const SizedBox(width: 20),
                _Tab('Follow', RoomTab.follow, selected, onTabChanged),
                const Spacer(),
                IconButton(
                  onPressed: onGames,
                  tooltip: 'Games',
                  icon: const Icon(Icons.sports_esports_outlined, color: Colors.white, size: 27),
                ),
                // Search icon with crescent-moon detail (no "+" button)
                IconButton(
                  onPressed: onSearch,
                  tooltip: 'Search',
                  icon: const Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(Icons.search_rounded, color: Colors.white, size: 28),
                      Positioned(
                        top: -5,
                        right: -7,
                        child: Icon(Icons.nightlight_round, color: Color(0xFFFDE047), size: 13),
                      ),
                    ],
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

class _Tab extends StatelessWidget {
  final String label;
  final RoomTab tab;
  final RoomTab selected;
  final ValueChanged<RoomTab> onTap;
  const _Tab(this.label, this.tab, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) {
    final active = tab == selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(tab),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 150),
              style: TextStyle(
                color: active ? Colors.white : Colors.white70,
                fontSize: active ? 19 : 16,
                fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              ),
              child: Text(label),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 3,
              width: active ? 24 : 0,
              decoration: BoxDecoration(color: AppColors.gold, borderRadius: BorderRadius.circular(3)),
            ),
          ],
        ),
      ),
    );
  }
}
