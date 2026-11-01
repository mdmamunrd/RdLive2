import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum NavItem { hot, party, chat, me }

/// Floating pill nav: Hot | Party | [Go Live] | Chat | Me
class RdBottomNav extends StatefulWidget {
  final NavItem selected;
  final ValueChanged<NavItem> onSelect;
  final VoidCallback onGoLive;

  const RdBottomNav({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onGoLive,
  });

  @override
  State<RdBottomNav> createState() => _RdBottomNavState();
}

class _RdBottomNavState extends State<RdBottomNav> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: SizedBox(
          height: 82,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Container(
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(color: AppColors.header1.withValues(alpha: .25), blurRadius: 28, offset: const Offset(0, 8)),
                  ],
                ),
                child: Row(
                  children: [
                    _item(NavItem.hot, Icons.local_fire_department_rounded, 'Hot'),
                    _item(NavItem.party, Icons.videocam_rounded, 'Party'),
                    const Expanded(child: SizedBox()), // space for Go Live
                    _item(NavItem.chat, Icons.chat_bubble_rounded, 'Chat'),
                    _item(NavItem.me, Icons.person_rounded, 'Me'),
                  ],
                ),
              ),
              Positioned(top: 0, child: _goLive()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(NavItem item, IconData icon, String label) {
    final active = widget.selected == item;
    final color = active ? AppColors.purple : AppColors.inactive;
    return Expanded(
      child: InkResponse(
        onTap: () => widget.onSelect(item),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 25),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _goLive() {
    return GestureDetector(
      onTap: widget.onGoLive,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, __) => Container(
                    width: 64 + 30 * _pulse.value,
                    height: 64 + 30 * _pulse.value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.pink.withValues(alpha: .35 * (1 - _pulse.value)),
                    ),
                  ),
                ),
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.pink, Color(0xFF8B5CF6)],
                    ),
                    boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 10, offset: Offset(0, 4))],
                  ),
                  child: const Icon(Icons.sensors_rounded, color: Colors.white, size: 32),
                ),
              ],
            ),
          ),
          const SizedBox(height: 1),
          const Text('Go Live',
              style: TextStyle(color: AppColors.purple, fontSize: 11, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
