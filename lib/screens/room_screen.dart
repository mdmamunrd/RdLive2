import 'dart:async';

import 'package:flutter/material.dart';

import '../models/pk_models.dart';
import '../models/room_models.dart';
import '../permissions/permission_prompts.dart';
import '../services/pk_controller.dart';
import '../services/room_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/festive_decor.dart';
import '../widgets/pk_battle_overlay.dart';
import '../widgets/room_control_panel.dart';
import '../widgets/seat_action_sheet.dart';
import '../widgets/seat_grid.dart';

/// Live room screen (mock data). Composes: seat grid, PK battle overlay,
/// control panel and the bottom action bar. The "⋮" menu has demo switches
/// (audio/video, 4/8 seats, act as audience/moderator/host, PK on/off).
class RoomScreen extends StatefulWidget {
  final String title;
  final SeatLayout initialLayout;
  final RoomRole initialRole;

  const RoomScreen({
    super.key,
    this.title = 'RAFIYA',
    this.initialLayout = SeatLayout.eight,
    this.initialRole = RoomRole.audience,
  });

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  late final RoomController _room;
  late final PkController _pk;
  StreamSubscription<String>? _sub;

  SeatMediaMode _media = SeatMediaMode.audio;
  bool _pkVisible = false;

  @override
  void initState() {
    super.initState();
    _room = RoomController(layout: widget.initialLayout, myRole: widget.initialRole);
    _pk = PkController(
      hostA: PkHost(id: 'host', name: widget.title, countryCode: 'SA'),
      hostB: const PkHost(id: 'host_b', name: 'KKAGENCY', countryCode: 'BD'),
    );
    _sub = _room.messages.listen(_toast);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _room.dispose();
    _pk.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 90),
          duration: const Duration(milliseconds: 1600),
        ),
      );
  }

  void _togglePk() {
    setState(() {
      _pk.reset();
      _pkVisible = !_pkVisible;
    });
  }

  void _onMenu(String v) {
    switch (v) {
      case 'audio':
        setState(() => _media = SeatMediaMode.audio);
      case 'video':
        setState(() => _media = SeatMediaMode.video);
      case 'four':
        _room.setLayout(SeatLayout.four);
      case 'eight':
        _room.setLayout(SeatLayout.eight);
      case 'audience':
        _room.setMyRole(RoomRole.audience);
      case 'moderator':
        _room.setMyRole(RoomRole.moderator);
      case 'host':
        _room.setMyRole(RoomRole.host);
      case 'pk':
        _togglePk();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepPurple,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.deepPurple, Color(0xFF1E0B3A)],
          ),
        ),
        child: Stack(
          children: [
            const Positioned.fill(child: ArchPattern(opacity: .35)),
            SafeArea(
              child: Column(
                children: [
                  _header(),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_room, _pk]),
                      builder: (context, _) => SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 8, bottom: 24),
                        child: Column(
                          children: [
                            if (_pkVisible) ...[
                              PkBattleOverlay(
                                controller: _pk,
                                isHost: _room.isHost,
                                showDemoControls: true,
                                onClose: _togglePk,
                              ),
                              const SizedBox(height: 16),
                            ],
                            SeatGrid(
                              controller: _room,
                              mediaMode: _media,
                              onSeatTap: (seat) =>
                                  SeatActionSheet.show(context, controller: _room, seat: seat),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  AnimatedBuilder(animation: _room, builder: (context, _) => _bottomBar()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- header ---------------------------------------------------------------

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                const Text('ID 10293847 · 128 listening',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ),
          ),
          AnimatedBuilder(
            animation: _room,
            builder: (context, _) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(_room.myRole.label,
                  style: const TextStyle(
                      color: AppColors.gold, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
            tooltip: 'Demo controls',
            onSelected: _onMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'audio', child: Text('Audio room')),
              PopupMenuItem(value: 'video', child: Text('Video room')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'four', child: Text('4 seats')),
              PopupMenuItem(value: 'eight', child: Text('8 seats')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'audience', child: Text('Act as Audience')),
              PopupMenuItem(value: 'moderator', child: Text('Act as Moderator')),
              PopupMenuItem(value: 'host', child: Text('Act as Host')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'pk', child: Text('Toggle PK battle')),
            ],
          ),
        ],
      ),
    );
  }

  // ---- bottom action bar ------------------------------------------------------

  Widget _bottomBar() {
    final seat = _room.mySeat;
    final pending = _room.requests.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: .35)),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 40,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Text('Say something…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white54)),
              ),
            ),
            if (seat != null) ...[
              const SizedBox(width: 8),
              _RoundIcon(
                icon: seat.micActive ? Icons.mic_rounded : Icons.mic_off_rounded,
                color: seat.micActive ? Colors.white : Colors.redAccent,
                tooltip: 'Microphone',
                onTap: _onToggleMic,
              ),
              if (_media == SeatMediaMode.video || seat.cameraOn) ...[
                const SizedBox(width: 8),
                _RoundIcon(
                  icon: seat.cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                  color: seat.cameraOn ? Colors.white : Colors.white54,
                  tooltip: 'Camera',
                  onTap: _onToggleCamera,
                ),
              ],
            ],
            ..._seatButton(),
            const SizedBox(width: 8),
            _RoundIcon(
              icon: Icons.card_giftcard_rounded,
              color: AppColors.pink,
              tooltip: 'Send gift to host',
              onTap: _giftToHost,
            ),
            if (_room.canModerate) ...[
              const SizedBox(width: 8),
              _RoundIcon(
                icon: Icons.admin_panel_settings_rounded,
                color: AppColors.gold,
                tooltip: 'Room controls',
                badge: pending,
                onTap: () => RoomControlPanel.show(context, _room),
              ),
            ],
            if (_room.isHost) ...[
              const SizedBox(width: 8),
              _RoundIcon(
                icon: Icons.flash_on_rounded,
                color: _pkVisible ? PkColors.red : Colors.white,
                tooltip: _pkVisible ? 'Close PK' : 'PK battle',
                onTap: _togglePk,
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _seatButton() {
    final seat = _room.mySeat;
    if (seat != null) {
      if (seat.index == 0) return const [];
      return [
        const SizedBox(width: 8),
        _RoundIcon(
          icon: Icons.logout_rounded,
          color: Colors.redAccent,
          tooltip: 'Leave seat',
          onTap: _room.leaveSeat,
        ),
      ];
    }
    if (_room.myRequest != null) {
      return [
        const SizedBox(width: 8),
        _RoundIcon(
          icon: Icons.hourglass_top_rounded,
          color: AppColors.gold,
          tooltip: 'Cancel request',
          onTap: _room.cancelRequest,
        ),
      ];
    }
    return [
      const SizedBox(width: 8),
      _RoundIcon(
        icon: Icons.event_seat_rounded,
        tooltip: 'Join a seat',
        onTap: _joinSeat,
      ),
    ];
  }

  /// Asks for the microphone before a seat is requested (voice seats need it).
  Future<void> _joinSeat() async {
    final i = _room.seats.indexWhere((s) => s.isEmpty);
    if (i == -1) {
      _toast('No free seats');
      return;
    }
    if (!await PermissionPrompts.forVoice(context)) return;
    if (!mounted) return;
    _room.requestToJoin(i);
  }

  /// Asks for the microphone only when the user is switching it ON.
  Future<void> _onToggleMic() async {
    final seat = _room.mySeat;
    if (seat != null && !seat.micOn && !await PermissionPrompts.forVoice(context)) return;
    if (!mounted) return;
    _room.toggleMic();
  }

  /// Asks for the camera only when the user is switching it ON.
  Future<void> _onToggleCamera() async {
    final seat = _room.mySeat;
    if (seat != null && !seat.cameraOn && !await PermissionPrompts.forCamera(context)) return;
    if (!mounted) return;
    _room.toggleCamera();
  }

  void _giftToHost() {
    final host = _room.roomHost;
    if (host == null || host.id == RoomController.meId) {
      _toast('You are the host');
      return;
    }
    GiftPickerSheet.show(context, controller: _room, receiver: host);
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final int badge;
  final VoidCallback onTap;

  const _RoundIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = Colors.white,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Badge(
          isLabelVisible: badge > 0,
          label: Text('$badge'),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .14), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }
}
