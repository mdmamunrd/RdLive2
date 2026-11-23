import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../models/room_models.dart';
import '../services/agora_service.dart';
import '../services/room_api.dart';
import '../services/room_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/festive_decor.dart';
import '../widgets/party_seat_board.dart';
import '../widgets/room_control_panel.dart';
import '../widgets/seat_action_sheet.dart';

/// Host seat + 9 guest seats.
const int _kPartySeats = 10;

class _ChatLine {
  final int level;
  final String name;
  final String text;
  const _ChatLine({required this.level, required this.name, required this.text});
}

/// The host's own audio party room. Connects to Agora as the broadcaster
/// (token from the Netlify token function) and shows the party room layout.
/// Seats, viewers and chat of other users arrive with the server.
class HostRoomScreen extends StatefulWidget {
  const HostRoomScreen({super.key});

  @override
  State<HostRoomScreen> createState() => _HostRoomScreenState();
}

class _HostRoomScreenState extends State<HostRoomScreen> {
  static const String _tokenUrl =
      'https://graceful-stroopwafel-7d16c1.netlify.app/api/token';

  late final RoomController _room;
  StreamSubscription<String>? _sub;
  final TextEditingController _chatCtrl = TextEditingController();
  final List<_ChatLine> _chat = [];

  RtcEngine? _engine;
  int? _roomId;
  String _channel = '';
  bool _joined = false;
  bool _speakerOn = true;
  bool _lastMicActive = true;
  bool _ending = false;
  String _error = '';
  final Set<int> _remoteUids = {};

  String get _myName {
    final n = FirebaseAuth.instance.currentUser?.displayName?.trim() ?? '';
    return n.isEmpty ? 'Host' : n;
  }

  String? get _myPhoto => FirebaseAuth.instance.currentUser?.photoURL;

  @override
  void initState() {
    super.initState();
    _room = RoomController(
      layout: SeatLayout.eight,
      myRole: RoomRole.host,
      seedMockData: false,
      autoApproveDemo: false,
      seatCount: _kPartySeats,
      hostSeatUnnumbered: true,
    );
    _room.requestToJoin(0); // the host takes seat 0
    _room.addListener(_syncMic);
    _sub = _room.messages.listen(_toast);
    _chat.add(_ChatLine(level: 1, name: _myName, text: 'You started the live'));
    _start();
  }

  @override
  void dispose() {
    _room.removeListener(_syncMic);
    _sub?.cancel();
    _room.dispose();
    _chatCtrl.dispose();
    _teardown();
    super.dispose();
  }

  // ---- Agora ------------------------------------------------------------------

  Future<void> _teardown() async {
    final room = _roomId;
    _roomId = null;
    if (room != null) {
      try {
        await RoomApi.instance.endRoom(room);
      } catch (_) {}
    }
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await engine.leaveChannel();
      await engine.release();
    } catch (_) {}
  }

  Future<String> _fetchToken(String channel) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw 'Please sign in again.';
    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw 'Could not read your login. Please sign in again.';
    }

    final res = await http
        .post(
          Uri.parse(_tokenUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          body: jsonEncode({'channel': channel, 'role': 'host'}),
        )
        .timeout(const Duration(seconds: 20));

    if (res.statusCode != 200) {
      throw 'Token server error (${res.statusCode}): ${res.body}';
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final token = data['token'] as String?;
    if (token == null || token.isEmpty) {
      throw 'Token server returned no token.';
    }
    return token;
  }

  Future<void> _renewToken() async {
    try {
      final token = await _fetchToken(_channel);
      await _engine?.renewToken(token);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not renew token: $e');
    }
  }

  Future<void> _start() async {
    setState(() {
      _error = '';
      _joined = false;
      _remoteUids.clear();
    });

    try {
      await _teardown();

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw 'Please sign in again.';

      final created = await RoomApi.instance.createRoom(
        title: _myName,
        seatCount: 12,
        mediaMode: 'audio',
      );
      _roomId = (created['room_id'] as num).toInt();
      final channel =
          created['agora_channel'] as String? ?? 'room_${user.uid}';

      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        throw 'Microphone permission is needed to go live. Please allow it in phone settings.';
      }

      final token = await _fetchToken(channel);

      final engine = createAgoraRtcEngine();
      await engine.initialize(const RtcEngineContext(
        appId: AgoraService.appId,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
      ));
      _engine = engine;
      _channel = channel;

      engine.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          if (mounted) setState(() => _joined = true);
        },
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          if (mounted) setState(() => _remoteUids.add(remoteUid));
        },
        onUserOffline: (RtcConnection connection, int remoteUid,
            UserOfflineReasonType reason) {
          if (mounted) setState(() => _remoteUids.remove(remoteUid));
        },
        onTokenPrivilegeWillExpire: (RtcConnection connection, String token) {
          _renewToken();
        },
        onError: (ErrorCodeType err, String msg) {
          if (mounted) setState(() => _error = 'Agora error: $err $msg');
        },
      ));

      await engine.enableAudio();
      await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

      await engine.joinChannel(
        token: token,
        channelId: channel,
        uid: 0,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          publishMicrophoneTrack: true,
          publishCameraTrack: false,
          autoSubscribeAudio: true,
          autoSubscribeVideo: false,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// The controller is the single source of truth for the host's mic switch;
  /// Agora follows it.
  void _syncMic() {
    final active = _room.mySeat?.micActive ?? false;
    if (active == _lastMicActive) return;
    _lastMicActive = active;
    final engine = _engine;
    if (engine != null) unawaited(engine.muteLocalAudioStream(!active));
  }

  void _toggleSpeaker() {
    final next = !_speakerOn;
    setState(() => _speakerOn = next);
    final engine = _engine;
    if (engine != null) unawaited(engine.muteAllRemoteAudioStreams(!next));
  }

  // ---- leaving ----------------------------------------------------------------

  Future<void> _onBack() async {
    if (_ending) return;
    if (!_joined) {
      _ending = true;
      await _teardown();
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End live?'),
        content: const Text('Your room will be closed for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End live'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _ending = true;
    await _teardown();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ---- small helpers ------------------------------------------------------------

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

  void _sendChat(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    setState(() {
      _chat.add(_ChatLine(level: 1, name: _myName, text: text));
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
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.call_end_rounded, color: Colors.redAccent),
              title: const Text('End live', style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.of(ctx).pop();
                _onBack();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
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
              SafeArea(child: _joined ? _roomView() : _statusView()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusView() {
    if (_error.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.orangeAccent, size: 48),
            const SizedBox(height: 12),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _start,
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: _onBack,
              child: const Text('Back', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );
    }
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppColors.gold),
          SizedBox(height: 16),
          Text('Going live…', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _roomView() {
    return Column(
      children: [
        AnimatedBuilder(animation: _room, builder: (context, _) => _topArea()),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            child: Column(
              children: [
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
        AnimatedBuilder(animation: _room, builder: (context, _) => _chatAndActions()),
        _bottomBar(),
      ],
    );
  }

  // ---- top area -----------------------------------------------------------------

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
                tooltip: 'End live',
                onTap: _onBack,
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
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              _error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _hostCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: AppColors.gold.withValues(alpha: .6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AvatarCircle(name: _myName, url: _myPhoto, size: 40),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _myName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
                ),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Colors.redAccent, size: 8),
                    SizedBox(width: 4),
                    Text('LIVE',
                        style: TextStyle(
                            color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700)),
                  ],
                ),
              ],
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
              '${_remoteUids.length}',
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

  // ---- chat and mic ---------------------------------------------------------------

  Widget _chatAndActions() {
    final micOn = _room.mySeat?.micActive ?? false;
    return SizedBox(
      height: 132,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: _chatList()),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _room.toggleMic,
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
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: micOn ? AppColors.gold : Colors.redAccent,
                      ),
                      child: Icon(
                        micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                        color: micOn ? Colors.black : Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      micOn ? 'Mic on' : 'Mic off',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
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
              onTap: _toggleSpeaker,
            ),
            const SizedBox(width: 8),
            _RoundIcon(
              icon: Icons.card_giftcard_rounded,
              color: AppColors.pink,
              tooltip: 'Gifts',
              onTap: () => _toast('Gifts will open when the server is ready'),
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
