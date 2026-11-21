import 'dart:async';

import 'package:flutter/material.dart';

import '../models/pk_models.dart';
import '../models/room_models.dart';
import '../permissions/permission_prompts.dart';
import '../services/pk_controller.dart';
import '../services/room_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/festive_decor.dart';
import '../widgets/party_seat_board.dart';
import '../widgets/pk_battle_overlay.dart';
import '../widgets/room_control_panel.dart';
import '../widgets/seat_action_sheet.dart';

/// Host seat + 9 guest seats.
const int _kPartySeats = 10;

/// Audio party room (mock data): host card, viewer chip, host and VIP seats,
/// 9 numbered seats, rules notice, local chat, Join Call and the bottom bar.
/// The "more" button has demo switches (act as audience/moderator/host, PK).
class RoomScreen extends StatefulWidget {
  final String title;

  /// Kept so older callers still compile. The party room always has 9 guest seats.
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

class _ChatLine {
  final int level;
  final String name;
  final String text;
  const _ChatLine({required this.level, required this.name, required this.text});
}

class _RoomScreenState extends State<RoomScreen> {
  late final RoomController _room;
  late final PkController _pk;
  StreamSubscription<String>? _sub;
  final TextEditingController _chatCtrl = TextEditingController();
  final List<_ChatLine> _chat = [
    const _ChatLine(level: 1, name: 'N/A', text: 'Joined the room'),
  ];

  bool _pkVisible = false;
  bool _following = false;
  bool _speakerOn = true;

  @override
  void initState() {
    super.initState();
    _room = RoomController(
      layout: widget.initialLayout,
      myRole: widget.initialRole,
      seatCount: _kPartySeats,
      hostSeatUnnumbered: true,
    );
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
    _chatCtrl.dispose();
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
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 130),
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

  void _sendChat(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    setState(() {
      _chat.add(_ChatLine(level: _room.me.level, name: 'You', text: text));
    });
    _chatCtrl.clear();
  }

  void _openMore() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF241046),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'Demo controls',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            for (final r in RoomRole.values)
              ListTile(
                leading: const Icon(Icons.person_rounded, color: Colors.white70),
                title: Text('Act as ${r.label}', style: const TextStyle(color: Colors.white)),
                trailing: _room.myRole == r
                    ? const Icon(Icons.check_rounded, color: AppColors.gold)
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _room.setMyRole(r);
                },
              ),
            ListTile(
              leading: const Icon(Icons.flash_on_rounded, color: Colors.white70),
              title: Text(
                _pkVisible ? 'Close PK battle' : 'PK battle',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _togglePk();
              },
            ),
          ],
        ),
      ),
    );
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
                  AnimatedBuilder(animation: _room, builder: (context, _) => _topArea()),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_room, _pk]),
                      builder: (context, _) => SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 6, bottom: 12),
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
                            PartySeatBoard(
                              controller: _room,
                              onSeatTap: (seat) =>
                                  SeatActionSheet.show(context, controller: _room, seat: seat),
                              onVipTap: () => _toast('VIP seats will open soon'),
                            ),
                            const SizedBox(height: 12),
                            _notice(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  AnimatedBuilder(animation: _room, builder: (context, _) => _chatAndActions()),
                  _bottomBar(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- top area ---------------------------------------------------------------

  Widget _topArea() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: _hostCard(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _viewerChip(),
              const SizedBox(width: 8),
              _RoundIcon(
                icon: Icons.close_rounded,
                tooltip: 'Leave room',
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              _pill('💎', '0'),
              const SizedBox(width: 8),
              _pill(null, '0'),
              const Spacer(),
              if (_room.canModerate)
                _RoundIcon(
                  icon: Icons.settings_rounded,
                  color: AppColors.gold,
                  tooltip: 'Room controls',
                  badge: _room.requests.length,
                  onTap: () => RoomControlPanel.show(context, _room),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hostCard() {
    final host = _room.roomHost;
    final name = host?.name ?? widget.title;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: AppColors.gold.withValues(alpha: .6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AvatarCircle(name: name, url: host?.avatarUrl, size: 40),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
                ),
                const Text(
                  'ID 10293847',
                  style: TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => setState(() => _following = !_following),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _following ? Colors.white24 : AppColors.gold,
              ),
              child: Icon(
                _following ? Icons.check_rounded : Icons.add_rounded,
                color: _following ? Colors.white : Colors.black,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewerChip() {
    return GestureDetector(
      onTap: () => _toast('The viewer list comes with the server'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .35),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_alt_rounded, color: Colors.white70, size: 16),
            const SizedBox(width: 4),
            Text(
              '${_room.participants.length}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String? emoji, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (emoji != null) ...[
            Text(emoji, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
          ],
          Text(value,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _notice() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xCC1A0B2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'Keep the room friendly. Sexual or abusive content is not allowed and '
        'violators will be banned. Never share your phone number or location.',
        style: TextStyle(color: Colors.white, fontSize: 13, height: 1.35),
      ),
    );
  }

  // ---- chat and join call -----------------------------------------------------

  Widget _chatAndActions() {
    return SizedBox(
      height: 132,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: _chatList()),
            const SizedBox(width: 8),
            _joinColumn(),
          ],
        ),
      ),
    );
  }

  Widget _chatList() {
    return ListView.builder(
      reverse: true,
      padding: EdgeInsets.zero,
      itemCount: _chat.length,
      itemBuilder: (context, i) {
        final m = _chat[_chat.length - 1 - i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text.rich(
            TextSpan(
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _LevelChip(m.level),
                ),
                const TextSpan(text: ' '),
                TextSpan(
                  text: m.name,
                  style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700),
                ),
                TextSpan(text: '  ${m.text}'),
              ],
            ),
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        );
      },
    );
  }

  Widget _joinColumn() {
    final seat = _room.mySeat;
    if (seat != null) {
      final micOn = seat.micActive;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _miniAction(
            icon: micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
            label: micOn ? 'Mic on' : 'Mic off',
            color: micOn ? Colors.white : Colors.redAccent,
            onTap: _onToggleMic,
          ),
          if (seat.index != 0) ...[
            const SizedBox(height: 8),
            _miniAction(
              icon: Icons.logout_rounded,
              label: 'Leave',
              color: Colors.redAccent,
              onTap: _room.leaveSeat,
            ),
          ],
        ],
      );
    }
    if (_room.myRequest != null) {
      return _joinCallBox(
        icon: Icons.hourglass_top_rounded,
        label: 'Requested',
        onTap: _room.cancelRequest,
      );
    }
    return _joinCallBox(icon: Icons.add_rounded, label: 'Join Call', onTap: _joinSeat);
  }

  Widget _joinCallBox({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 88,
        height: 96,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .3),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.gold),
              child: Icon(icon, color: Colors.black, size: 20),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                  color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 88,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .3),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // ---- bottom bar -------------------------------------------------------------

  Widget _bottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: .35)),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _chatCtrl,
                style: const TextStyle(color: Colors.white),
                textInputAction: TextInputAction.send,
                onSubmitted: _sendChat,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Say hi…',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: .12),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _RoundIcon(
              icon: _speakerOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              color: _speakerOn ? AppColors.gold : Colors.white54,
              tooltip: 'Room sound',
              onTap: () => setState(() => _speakerOn = !_speakerOn),
            ),
            const SizedBox(width: 8),
            _RoundIcon(
              icon: Icons.card_giftcard_rounded,
              color: AppColors.pink,
              tooltip: 'Send gift to host',
              onTap: _giftToHost,
            ),
            const SizedBox(width: 8),
            _RoundIcon(
              icon: Icons.more_horiz_rounded,
              tooltip: 'More',
              onTap: _openMore,
            ),
          ],
        ),
      ),
    );
  }

  // ---- actions ----------------------------------------------------------------

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

  void _giftToHost() {
    final host = _room.roomHost;
    if (host == null || host.id == RoomController.meId) {
      _toast('You are the host');
      return;
    }
    GiftPickerSheet.show(context, controller: _room, receiver: host);
  }
}

class _LevelChip extends StatelessWidget {
  final int level;
  const _LevelChip(this.level);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF14B8A6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Lv$level',
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
      ),
    );
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
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .14), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }
}
