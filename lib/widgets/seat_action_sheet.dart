import 'package:flutter/material.dart';

import '../models/room_models.dart';
import '../permissions/permission_prompts.dart';
import '../services/room_controller.dart';
import '../theme/app_theme.dart';
import 'avatar_circle.dart';
import 'sheet_frame.dart';

/// Bottom sheet shown when a seat is tapped. The content depends on the seat
/// state and on the viewer's role:
///  - empty seat   : request to join / cancel request (staff: take seat, lock)
///  - locked seat  : unlock (staff only)
///  - my own seat  : mic, camera, leave
///  - other's seat : view profile, send gift, mute / remove (staff only)
class SeatActionSheet {
  static Future<void> show(
    BuildContext context, {
    required RoomController controller,
    required Seat seat,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SeatSheetBody(
        hostContext: context,
        controller: controller,
        seatIndex: seat.index,
      ),
    );
  }
}

class _SeatSheetBody extends StatelessWidget {
  final BuildContext hostContext; // still valid after the sheet closes
  final RoomController controller;
  final int seatIndex;

  const _SeatSheetBody({
    required this.hostContext,
    required this.controller,
    required this.seatIndex,
  });

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          if (seatIndex >= controller.seats.length) return const SizedBox.shrink();
          final seat = controller.seats[seatIndex];
          switch (seat.status) {
            case SeatStatus.locked:
              return _locked(context, seat);
            case SeatStatus.empty:
              return _empty(context, seat);
            case SeatStatus.occupied:
              return seat.user!.id == RoomController.meId
                  ? _mine(context, seat)
                  : _other(context, seat);
          }
        },
      ),
    );
  }

  void _close(BuildContext context) => Navigator.of(context).pop();

  /// Asks for the microphone first, then requests / takes the seat.
  Future<void> _join(BuildContext context, int seatIndex) async {
    if (!await PermissionPrompts.forVoice(hostContext)) return;
    if (!hostContext.mounted) return;
    controller.requestToJoin(seatIndex);
    if (context.mounted) _close(context);
  }

  /// Asks for the microphone only when the user is switching it ON.
  Future<void> _toggleMic() async {
    final seat = controller.mySeat;
    if (seat != null && !seat.micOn && !await PermissionPrompts.forVoice(hostContext)) return;
    if (!hostContext.mounted) return;
    controller.toggleMic();
  }

  /// Asks for the camera only when the user is switching it ON.
  Future<void> _toggleCamera() async {
    final seat = controller.mySeat;
    if (seat != null && !seat.cameraOn && !await PermissionPrompts.forCamera(hostContext)) return;
    if (!hostContext.mounted) return;
    controller.toggleCamera();
  }

  // ---- locked ---------------------------------------------------------------
  Widget _locked(BuildContext context, Seat seat) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _Title(icon: Icons.lock_rounded, text: 'Seat ${seat.index + 1} is locked'),
      if (controller.canModerate)
        _ActionTile(
          icon: Icons.lock_open_rounded,
          label: 'Unlock seat',
          onTap: () {
            controller.unlockSeat(seat.index);
            _close(context);
          },
        )
      else
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Only the host can unlock this seat.', style: TextStyle(color: Colors.black54)),
        ),
    ]);
  }

  // ---- empty ----------------------------------------------------------------
  Widget _empty(BuildContext context, Seat seat) {
    final staff = controller.canModerate;
    final myReq = controller.myRequest;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _Title(icon: Icons.event_seat_rounded, text: 'Seat ${seat.index + 1}'),
      if (staff) ...[
        if (!controller.isSeated)
          _ActionTile(
            icon: Icons.login_rounded,
            label: 'Take this seat',
            onTap: () => _join(context, seat.index),
          ),
        if (seat.index != 0)
          _ActionTile(
            icon: Icons.lock_rounded,
            label: 'Lock seat',
            onTap: () {
              controller.lockSeat(seat.index);
              _close(context);
            },
          ),
      ] else if (myReq != null)
        _ActionTile(
          icon: Icons.close_rounded,
          label: 'Cancel join request',
          color: Colors.redAccent,
          onTap: () {
            controller.cancelRequest();
            _close(context);
          },
        )
      else if (controller.isSeated)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('You are already on a seat.', style: TextStyle(color: Colors.black54)),
        )
      else
        _ActionTile(
          icon: Icons.back_hand_rounded,
          label: controller.requireApproval ? 'Request to join' : 'Join this seat',
          onTap: () => _join(context, seat.index),
        ),
    ]);
  }

  // ---- my seat ----------------------------------------------------------------
  Widget _mine(BuildContext context, Seat seat) {
    final user = seat.user!;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _ProfileHeader(user: user, subtitle: 'Seat ${seat.index + 1} · You'),
      const SizedBox(height: 4),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        activeThumbColor: AppColors.violet,
        secondary: Icon(seat.micActive ? Icons.mic_rounded : Icons.mic_off_rounded,
            color: seat.micActive ? AppColors.violet : Colors.redAccent),
        title: const Text('Microphone'),
        subtitle: user.isMuted ? const Text('Muted by the host') : null,
        value: seat.micActive,
        onChanged: user.isMuted ? null : (_) => _toggleMic(),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        activeThumbColor: AppColors.violet,
        secondary: Icon(seat.cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
            color: seat.cameraOn ? AppColors.violet : Colors.black45),
        title: const Text('Camera'),
        value: seat.cameraOn,
        onChanged: (_) => _toggleCamera(),
      ),
      if (seat.index != 0)
        _ActionTile(
          icon: Icons.logout_rounded,
          label: 'Leave seat',
          color: Colors.redAccent,
          onTap: () {
            controller.leaveSeat();
            _close(context);
          },
        ),
    ]);
  }

  // ---- someone else's seat ------------------------------------------------------
  Widget _other(BuildContext context, Seat seat) {
    final user = seat.user!;
    final canAct = controller.canActOn(user);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _ProfileHeader(
        user: user,
        subtitle: 'Seat ${seat.index + 1}${seat.isMuted ? ' · muted' : ''}',
      ),
      const SizedBox(height: 4),
      _ActionTile(
        icon: Icons.person_rounded,
        label: 'View profile',
        onTap: () {
          _close(context);
          UserProfileSheet.show(hostContext, user);
        },
      ),
      _ActionTile(
        icon: Icons.card_giftcard_rounded,
        label: 'Send gift',
        onTap: () {
          _close(context);
          GiftPickerSheet.show(hostContext, controller: controller, receiver: user);
        },
      ),
      if (canAct) ...[
        _ActionTile(
          icon: user.isMuted ? Icons.mic_rounded : Icons.mic_off_rounded,
          label: user.isMuted ? 'Unmute' : 'Mute',
          onTap: () {
            user.isMuted ? controller.unmuteUser(user.id) : controller.muteUser(user.id);
            _close(context);
          },
        ),
        _ActionTile(
          icon: Icons.person_remove_rounded,
          label: 'Remove from seat',
          color: Colors.redAccent,
          onTap: () {
            controller.removeFromSeat(user.id);
            _close(context);
          },
        ),
      ],
    ]);
  }
}

// ======================================================================
// Profile sheet
// ======================================================================

class UserProfileSheet {
  static Future<void> show(BuildContext context, RoomUser user) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SheetFrame(child: _ProfileBody(user: user)),
    );
  }
}

class _ProfileBody extends StatefulWidget {
  final RoomUser user;
  const _ProfileBody({required this.user});

  @override
  State<_ProfileBody> createState() => _ProfileBodyState();
}

class _ProfileBodyState extends State<_ProfileBody> {
  bool _following = false; // local mock state

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      AvatarCircle(name: u.name, url: u.avatarUrl, size: 84),
      const SizedBox(height: 10),
      Text('${u.flagEmoji} ${u.name}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        _Chip(text: 'Lv.${u.level}', color: AppColors.violet),
        if (u.role != RoomRole.audience) _Chip(text: u.role.label, color: AppColors.lanternGold),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _following ? Colors.grey : AppColors.violet,
              shape: const StadiumBorder(),
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: () => setState(() => _following = !_following),
            icon: Icon(_following ? Icons.check_rounded : Icons.person_add_alt_1_rounded),
            label: Text(_following ? 'Following' : 'Follow'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              shape: const StadiumBorder(),
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: () => Navigator.of(context).pop(), // TODO: open 1-on-1 chat
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            label: const Text('Message'),
          ),
        ),
      ]),
    ]);
  }
}

// ======================================================================
// Gift picker (mock wallet)
// ======================================================================

class GiftPickerSheet {
  static Future<void> show(
    BuildContext context, {
    required RoomController controller,
    required RoomUser receiver,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SheetFrame(child: _GiftPickerBody(controller: controller, receiver: receiver)),
    );
  }
}

class _GiftPickerBody extends StatefulWidget {
  final RoomController controller;
  final RoomUser receiver;
  const _GiftPickerBody({required this.controller, required this.receiver});

  @override
  State<_GiftPickerBody> createState() => _GiftPickerBodyState();
}

class _GiftPickerBodyState extends State<_GiftPickerBody> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final gift = kMockGifts[_selected];
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          AvatarCircle(name: widget.receiver.name, url: widget.receiver.avatarUrl, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Gift to ${widget.receiver.name}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
          Text('🪙 ${c.coins}', style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < kMockGifts.length; i++)
              GestureDetector(
                onTap: () => setState(() => _selected = i),
                child: Container(
                  width: 92,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: i == _selected ? AppColors.violet.withValues(alpha: .10) : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: i == _selected ? AppColors.violet : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Column(children: [
                    Text(kMockGifts[i].emoji, style: const TextStyle(fontSize: 30)),
                    const SizedBox(height: 4),
                    Text(kMockGifts[i].name,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    Text('🪙 ${kMockGifts[i].price}',
                        style: const TextStyle(fontSize: 11, color: Colors.black54)),
                  ]),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.pink,
            shape: const StadiumBorder(),
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () {
            if (c.sendGift(widget.receiver.id, gift)) Navigator.of(context).pop();
          },
          icon: const Icon(Icons.send_rounded),
          label: Text('Send ${gift.emoji} · 🪙 ${gift.price}'),
        ),
      ]),
    );
  }
}

// ======================================================================
// small shared pieces
// ======================================================================

class _Title extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Title({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(icon, color: AppColors.violet),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
      );
}

class _ProfileHeader extends StatelessWidget {
  final RoomUser user;
  final String subtitle;
  const _ProfileHeader({required this.user, required this.subtitle});

  @override
  Widget build(BuildContext context) => Row(children: [
        AvatarCircle(name: user.name, url: user.avatarUrl, size: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${user.flagEmoji} ${user.name}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('Lv.${user.level} · $subtitle', style: const TextStyle(color: Colors.black54, fontSize: 13)),
          ]),
        ),
        if (user.role != RoomRole.audience) _Chip(text: user.role.label, color: AppColors.lanternGold),
      ]);
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _ActionTile({required this.icon, required this.label, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textDark;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color ?? AppColors.violet),
      title: Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}
