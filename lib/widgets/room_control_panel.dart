import 'package:flutter/material.dart';

import '../models/room_models.dart';
import '../services/room_controller.dart';
import '../theme/app_theme.dart';
import 'avatar_circle.dart';
import 'sheet_frame.dart';

/// True in the audio party room: the host seat has no number and the guest
/// seats are numbered 1, 2, 3... (the classic room numbers every seat from 1).
bool _isParty(RoomController c) => c.seatNumber(0) == '0';

String _seatLabel(RoomController c, int index) =>
    (index == 0 && _isParty(c)) ? 'host seat' : 'seat ${c.seatNumber(index)}';

/// Host / moderator control panel:
///  - Requests     : approve / reject pending seat requests
///  - Participants : mute, kick, ban
///  - Banned       : review and unban
/// Rules (enforced by the controller): staff can only act on people they
/// outrank, never on themselves.
class RoomControlPanel extends StatelessWidget {
  final RoomController controller;

  const RoomControlPanel({super.key, required this.controller});

  static Future<void> show(BuildContext context, RoomController controller) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RoomControlPanel(controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      heightFactor: 0.78,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final pending = controller.requests.length;
          return DefaultTabController(
            length: 3,
            child: Column(
              children: [
                Row(children: [
                  const Icon(Icons.admin_panel_settings_rounded, color: AppColors.violet),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Room controls',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  _RoleChip(role: controller.myRole),
                ]),
                const SizedBox(height: 6),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.violet,
                  title: const Text('Require approval for seat requests'),
                  value: controller.requireApproval,
                  onChanged: (v) => controller.requireApproval = v,
                ),
                if (controller.isHost && !_isParty(controller))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<SeatLayout>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: SeatLayout.four, label: Text('4 seats')),
                        ButtonSegment(value: SeatLayout.eight, label: Text('8 seats')),
                      ],
                      selected: {controller.layout},
                      onSelectionChanged: (s) => controller.setLayout(s.first),
                    ),
                  ),
                const SizedBox(height: 8),
                TabBar(
                  labelColor: AppColors.violet,
                  unselectedLabelColor: Colors.black45,
                  indicatorColor: AppColors.violet,
                  tabs: [
                    Tab(text: pending > 0 ? 'Requests ($pending)' : 'Requests'),
                    const Tab(text: 'People'),
                    Tab(text: 'Banned (${controller.banned.length})'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _RequestsTab(controller: controller),
                      _PeopleTab(controller: controller),
                      _BannedTab(controller: controller),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

class _RequestsTab extends StatelessWidget {
  final RoomController controller;
  const _RequestsTab({required this.controller});

  @override
  Widget build(BuildContext context) {
    final list = controller.requests;
    if (list.isEmpty) return const _Empty('No pending seat requests');
    return ListView.separated(
      padding: const EdgeInsets.only(top: 6),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = list[i];
        final wants = r.seatIndex == null ? 'any seat' : _seatLabel(controller, r.seatIndex!);
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: AvatarCircle(name: r.user.name, url: r.user.avatarUrl, size: 42),
          title: Text('${r.user.flagEmoji} ${r.user.name}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('Lv.${r.user.level} · wants $wants'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Reject',
              icon: const Icon(Icons.close_rounded, color: Colors.redAccent),
              onPressed: () => controller.rejectRequest(r.id),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.violet,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => controller.approveRequest(r.id),
              child: const Text('Approve'),
            ),
          ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// People (mute / kick / ban)
// ---------------------------------------------------------------------------

class _PeopleTab extends StatelessWidget {
  final RoomController controller;
  const _PeopleTab({required this.controller});

  @override
  Widget build(BuildContext context) {
    final people = controller.participants;
    if (people.isEmpty) return const _Empty('Nobody in the room');
    return ListView.separated(
      padding: const EdgeInsets.only(top: 6),
      itemCount: people.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final u = people[i];
        final seat = controller.seatOfUser(u.id);
        final isMe = u.id == RoomController.meId;
        final canAct = controller.canActOn(u);
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: AvatarCircle(name: u.name, url: u.avatarUrl, size: 42),
          title: Row(children: [
            Flexible(
              child: Text('${u.flagEmoji} ${isMe ? 'You' : u.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (u.role != RoomRole.audience) ...[
              const SizedBox(width: 6),
              _RoleChip(role: u.role),
            ],
          ]),
          subtitle: Text([
            'Lv.${u.level}',
            seat != null ? _seatLabel(controller, seat.index) : 'audience',
            if (u.isMuted) 'muted',
          ].join(' · ')),
          trailing: canAct
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: u.isMuted ? 'Unmute' : 'Mute',
                    icon: Icon(u.isMuted ? Icons.mic_rounded : Icons.mic_off_rounded,
                        color: u.isMuted ? AppColors.violet : Colors.black54),
                    onPressed: () =>
                        u.isMuted ? controller.unmuteUser(u.id) : controller.muteUser(u.id),
                  ),
                  IconButton(
                    tooltip: 'Kick out',
                    icon: const Icon(Icons.logout_rounded, color: Colors.orange),
                    onPressed: () async {
                      final ok = await _confirm(
                        context,
                        title: 'Kick ${u.name}?',
                        message: 'They will be removed from the room but can join again.',
                        action: 'Kick',
                      );
                      if (ok) controller.kickUser(u.id);
                    },
                  ),
                  IconButton(
                    tooltip: 'Ban from room',
                    icon: const Icon(Icons.block_rounded, color: Colors.redAccent),
                    onPressed: () async {
                      final ok = await _confirm(
                        context,
                        title: 'Ban ${u.name}?',
                        message: 'They will be removed and cannot join this room again until unbanned.',
                        action: 'Ban',
                      );
                      if (ok) controller.banUser(u.id);
                    },
                  ),
                ])
              : null,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Banned
// ---------------------------------------------------------------------------

class _BannedTab extends StatelessWidget {
  final RoomController controller;
  const _BannedTab({required this.controller});

  @override
  Widget build(BuildContext context) {
    final list = controller.banned;
    if (list.isEmpty) return const _Empty('No banned users');
    return ListView.separated(
      padding: const EdgeInsets.only(top: 6),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final u = list[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: AvatarCircle(name: u.name, url: u.avatarUrl, size: 42),
          title: Text('${u.flagEmoji} ${u.name}', style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('Lv.${u.level}'),
          trailing: TextButton(
            onPressed: () => controller.unbanUser(u.id),
            child: const Text('Unban'),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);

  @override
  Widget build(BuildContext context) => Center(
        child: Text(text, style: const TextStyle(color: Colors.black45)),
      );
}

class _RoleChip extends StatelessWidget {
  final RoomRole role;
  const _RoleChip({required this.role});

  @override
  Widget build(BuildContext context) {
    final color = role == RoomRole.host
        ? AppColors.lanternGold
        : role == RoomRole.moderator
            ? const Color(0xFF0EA5E9)
            : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: .15), borderRadius: BorderRadius.circular(20)),
      child: Text(role.label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}
