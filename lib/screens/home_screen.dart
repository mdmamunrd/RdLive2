import 'package:flutter/material.dart';

import '../models/live_room.dart';
import '../permissions/permission_prompts.dart';
import '../permissions/permission_service.dart';
import '../services/auth_service.dart';
import '../services/room_api.dart';
import '../theme/app_theme.dart';
import '../widgets/hero_banner.dart';
import '../widgets/home_header.dart';
import '../widgets/rd_bottom_nav.dart';
import '../widgets/room_card.dart';
import 'host_live_screen.dart';
import 'host_room_screen.dart';
import 'room_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  RoomTab _tab = RoomTab.discover;
  NavItem _nav = NavItem.hot;
  late Future<List<LiveRoom>> _rooms = RoomApi.instance.fetchRooms(_tab);

  void _load() => setState(() => _rooms = RoomApi.instance.fetchRooms(_tab));

  void _onTab(RoomTab t) {
    if (t == _tab) return;
    _tab = t;
    _load();
  }

  Future<void> _refresh() async {
    _load();
    try {
      await _rooms;
    } catch (_) {
      // The error view below already shows a Retry button.
    }
  }

  void _openRoom(LiveRoom room) {
    // Entering a room never needs a permission; ask for the mic in the background so voice seats work.
    PermissionPrompts.softAsk(PermissionService.voiceSet);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RoomScreen(title: room.hostName)),
    );
  }

  Future<void> _goLive() async {
    final mode = await showModalBottomSheet<LiveMode>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _GoLiveSheet(),
    );
    if (mode == null || !mounted) return;

    if (mode == LiveMode.video) {
      if (!await PermissionPrompts.forLive(context)) return; // camera + microphone
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => HostLiveScreen(mode: mode)),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HostRoomScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      extendBody: true,
      body: RefreshIndicator(
        onRefresh: _refresh,
        edgeOffset: 90,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: HomeHeader(
                selected: _tab,
                onTabChanged: _onTab,
                onGames: () {},
                onSearch: () {},
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
              sliver: SliverToBoxAdapter(child: HeroBanner()),
            ),
            FutureBuilder<List<LiveRoom>>(
              future: _rooms,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: EdgeInsets.only(top: 60),
                      child: Center(child: CircularProgressIndicator(color: AppColors.violet)),
                    ),
                  );
                }
                if (snap.hasError) {
                  return SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('Could not load rooms'),
                        TextButton(onPressed: _load, child: const Text('Retry')),
                      ]),
                    ),
                  );
                }
                final rooms = snap.data!;
                if (rooms.isEmpty) {
                  return const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('No live rooms right now')),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 120),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 14,
                      childAspectRatio: .8,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => RoomCard(room: rooms[i], index: i, onTap: () => _openRoom(rooms[i])),
                      childCount: rooms.length,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: RdBottomNav(
        selected: _nav,
        onSelect: (n) => setState(() => _nav = n),
        onGoLive: _goLive,
      ),
      floatingActionButton: null,
    );
  }

  // ignore: unused_element
  Future<void> _signOut() => AuthService.instance.signOut();
}

class _GoLiveSheet extends StatelessWidget {
  const _GoLiveSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Start a live',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.mic_rounded, color: AppColors.violet),
              title: const Text('Audio Party'),
              subtitle: const Text('Voice room with friends'),
              onTap: () => Navigator.of(context).pop(LiveMode.audio),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_rounded, color: AppColors.violet),
              title: const Text('Video Live'),
              subtitle: const Text('Go live with your camera'),
              onTap: () => Navigator.of(context).pop(LiveMode.video),
            ),
          ],
        ),
      ),
    );
  }
}
