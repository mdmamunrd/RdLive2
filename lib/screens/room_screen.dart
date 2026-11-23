import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../models/live_room.dart';
import '../models/room_models.dart';
import '../permissions/permission_prompts.dart';
import '../services/agora_service.dart';
import '../services/room_api.dart';
import '../services/room_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/festive_decor.dart';
import '../widgets/party_seat_board.dart';
import '../widgets/room_control_panel.dart';
import '../widgets/seat_action_sheet.dart';

/// Host seat + guest seats. The server room may define fewer or more seats;
/// the UI never shows fewer than this.
const int _kPartySeats = 10;

/// Real live room. Joins the backend room (`POST /v1/rooms/{id}/join`),
/// listens on the room's Agora channel as an audience member, and switches to
/// broadcaster (mic live for everyone) as soon as a seat is granted.
class RoomScreen extends StatefulWidget {
  final LiveRoom room;

  /// Sent only when the room is password protected.
  final String? joinPassword;

  const RoomScreen({
    super.key,
    required this.room,
    this.joinPassword,
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
  /// Agora token server (same deployment the host screens use).
  static const String _tokenUrl =
      'https://graceful-stroopwafel-7d16c1.netlify.app/api/token';

  late final RoomController _room;
  late final int _roomId;
  late final int _hostUserId;
  Timer? _poll;

  final TextEditingController _chatCtrl = TextEditingController();
  final List<_ChatLine> _chat = [];

  RtcEngine? _engine;
  String _channel = '';
  bool _serverJoined = false;
  bool _speakerOn = true;
  bool _ending = false;
  bool _following = false;
  bool _lastMicActive = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _roomId = int.tryParse(widget.room.id) ?? 0;
    _hostUserId = widget.room.hostId;
    _room = RoomController(
      layout: SeatLayout.eight,
      myRole: RoomRole.audience,
      seedMockData: false,
      autoApproveDemo: false,
      seatCount: widget.room.seatCount < _kPartySeats
          ? _kPartySeats
          : widget.room.seatCount,
      hostSeatUnnumbered: true,
    );
    _room.addListener(_syncMic);
    _chat.add(_ChatLine(level: 1, name: widget.room.hostName, text: 'Live now'));
    _enter();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _room.removeListener(_syncMic);
    _room.dispose();
    _chatCtrl.dispose();
    _teardown();
    super.dispose();
  }

  // ---- backend -------------------------------------------------------------

  Future<void> _enter() async {
    setState(() => _error = '');
    try {
      await RoomApi.instance.joinRoom(_roomId, password: widget.joinPassword);
      _serverJoined = true;
      final snap = await RoomApi.instance.roomSnapshot(_roomId);
      _room.applyServerSnapshot(snap);
      final info = (snap['room'] as Map<String, dynamic>?) ?? const {};
      _channel = (info['agora_channel'] as String?) ?? widget.room.agoraChannel ?? '';
      if (_channel.isEmpty) throw 'This live room has no media channel.';
      _loadFollowing();
      _refreshCoins();
      await _joinAgora();
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendly(e));
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _pull());
  }

  Future<void> _pull() async {
    if (_ending || !_serverJoined) return;
    try {
      final snap = await RoomApi.instance.roomSnapshot(_roomId);
      if (!mounted) return;
      _room.applyServerSnapshot(snap);
      _syncAgoraRole();
    } catch (_) {
      // Transient network issues keep the last known state; next poll retries.
    }
  }

  Future<void> _refreshCoins() async {
    try {
      final coins = await RoomApi.instance.myCoins();
      _room.setCoins(coins);
    } catch (_) {}
  }

  Future<void> _loadFollowing() async {
    final pid = widget.room.hostPublicId;
    if (pid == null || pid == 0) return;
    try {
      final card = await RoomApi.instance.get('/v1/users/$pid');
      if (!mounted) return;
      setState(() => _following = card['is_following'] as bool? ?? false);
    } catch (_) {}
  }

  String _friendly(Object e) {
    if (e is ApiException) {
      if (e.code == 'wrong_password') return 'Wrong room password.';
      return e.message;
    }
    return 'Could not connect to the live room. Check your connection and try again.';
  }

  // ---- Agora ------------------------------------------------------------------

  Future<void> _teardown() async {
    final engine = _engine;
    _engine = null;
    final roomId = _roomId;
    final joined = _serverJoined;
    _serverJoined = false;
    if (joined) {
      try {
        if (_room.isSeated) {
          await RoomApi.instance.leaveSeat(roomId);
        }
        await RoomApi.instance.leaveRoom(roomId);
      } catch (_) {}
    }
    if (engine == null) return;
    try {
      await engine.leaveChannel();
      await engine.release();
    } catch (_) {}
  }

  Future<String> _fetchToken() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return '';
      final idToken = await user.getIdToken();
      if (idToken == null || idToken.isEmpty) return '';
      final res = await http
          .post(
            Uri.parse(_tokenUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({'channel': _channel, 'role': 'audience'}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return '';
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return data['token'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _joinAgora() async {
    await [Permission.microphone].request();
    final engine = createAgoraRtcEngine();
    await engine.initialize(const RtcEngineContext(
      appId: AgoraService.appId,
      channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
    ));
    _engine = engine;
    engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (RtcConnection connection, int elapsed) {},
      onTokenPrivilegeWillExpire: (RtcConnection connection, String token) async {
        // Token-free App ID mode: nothing to renew.
      },
      onError: (ErrorCodeType err, String msg) {
        if (mounted) setState(() => _error = 'Audio error: $err');
      },
    ));
    await engine.enableAudio();
    await engine.setClientRole(role: ClientRoleType.clientRoleAudience);
    final token = await _fetchToken();
    await engine.joinChannel(
      token: token,
      channelId: _channel,
      uid: 0,
      options: const ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
        clientRoleType: ClientRoleType.clientRoleAudience,
        publishMicrophoneTrack: false,
        publishCameraTrack: false,
        autoSubscribeAudio: true,
        autoSubscribeVideo: true,
      ),
    );
  }

  /// Mirrors the server state onto the Agora engine: audience while only
  /// watching, broadcaster (mic published) once a seat is granted.
  void _syncAgoraRole() {
    final engine = _engine;
    if (engine == null) return;
    final seat = _room.mySeat;
    final micActive = seat?.micActive ?? false;
    if (seat != null && _room.myRole != RoomRole.audience) {
      unawaited(() async {
        await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
        await engine.muteLocalAudioStream(!micActive);
      }());
    } else if (seat == null) {
      unawaited(() async {
        await engine.setClientRole(role: ClientRoleType.clientRoleAudience);
        await engine.muteLocalAudioStream(true);
      }());
    }
  }

  /// The controller is the single source of truth for the mic switch;
  /// Agora follows it (only when we are the broadcaster).
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
    if (_room.isHost && _serverJoined) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('End live?'),
          content: const Text('Your room will be closed for everyone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
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
      try {
        await RoomApi.instance.endRoom(_roomId);
      } catch (_) {}
    } else {
      _ending = true;
    }
    await _teardown();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ---- seats / mic / chat / follow / gifts --------------------------------------

  Future<void> _joinSeat() async {
    if (!_serverJoined) return;
    final i = _room.seats.indexWhere((s) => s.isEmpty && s.index != 0);
    if (i == -1) {
      _toast('No free seats');
      return;
    }
    if (!await PermissionPrompts.forVoice(context)) return;
    if (!mounted) return;
    try {
      final res = await RoomApi.instance.requestSeat(_roomId, seatIndex: i);
      if (res['result'] == 'seated') {
        await _pull();
        if (!mounted) return;
        _toast('You are on the seat. Your mic is live.');
        _syncAgoraRole();
      } else {
        _toast('Request sent. Waiting for the host');
        _startPolling();
      }
    } catch (e) {
      _toast(_friendly(e));
    }
  }

  Future<void> _onToggleMic() async {
    final seat = _room.mySeat;
    if (seat == null) {
      _toast('Take a seat first');
      return;
    }
    final wantOn = !seat.micOn;
    if (wantOn && !await PermissionPrompts.forVoice(context)) return;
    if (!mounted) return;
    try {
      await RoomApi.instance.post('/v1/rooms/$_roomId/seats/me', body: {'mic': wantOn});
    } catch (e) {
      _toast(_friendly(e));
      return;
    }
    _room.toggleMic();
  }

  void _sendChat(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    setState(() {
      _chat.add(_ChatLine(level: _room.me.level, name: 'You', text: text));
    });
    _chatCtrl.clear();
  }

  Future<void> _toggleFollow() async {
    final pid = widget.room.hostPublicId;
    if (pid == null || pid == 0) {
      _toast('This host cannot be followed yet');
      return;
    }
    final next = !_following;
    setState(() => _following = next);
    try {
      await RoomApi.instance.setFollowing(pid, next);
    } catch (e) {
      if (!mounted) return;
      setState(() => _following = !next);
      _toast(_friendly(e));
    }
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

  void _giftTo(int receiverId, String receiverName) {
    if (!_serverJoined) return;
    GiftPickerSheet.show(
      context,
      controller: _room,
      receiver: _userForGift(receiverId, receiverName),
      roomId: _roomId,
    );
  }

  RoomUser _userForGift(int receiverId, String name) =>
      _room.participants.firstWhere((p) => p.id == '$receiverId',
          orElse: () => RoomUser(id: '$receiverId', name: name));

  // ---- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_serverJoined && _error.isNotEmpty) {
      return _errorScreen();
    }
    if (!_serverJoined) {
      return const Scaffold(
        backgroundColor: AppColors.deepPurple,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.gold),
              SizedBox(height: 16),
              Text('Joining the live room...', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }
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
                      animation: _room,
                      builder: (context, _) => SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 6, bottom: 12),
                        child: Column(
                          children: [
                            PartySeatBoard(
                              controller: _room,
                              onSeatTap: (seat) => SeatActionSheet.show(
                                context,
                                controller: _room,
                                seat: seat,
                                roomId: _roomId,
                              ),
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

  Widget _errorScreen() {
    return Scaffold(
      backgroundColor: AppColors.deepPurple,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.orangeAccent, size: 48),
            const SizedBox(height: 12),
            Text(_error, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.orangeAccent)),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.gold, foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _enter,
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: () {
                _ending = true;
                _teardown();
                Navigator.of(context).pop();
              },
              child: const Text('Back', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topArea() {
    final host = _room.roomHost;
    final name = host?.name ?? widget.room.hostName;
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
                    child: _hostCard(name, host?.avatarUrl),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _viewerChip(),
              const SizedBox(width: 8),
              _RoundIcon(
                icon: Icons.close_rounded,
                tooltip: _room.isHost ? 'End live' : 'Leave room',
                onTap: _onBack,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              _pill('💎', '${_room.coins}'),
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

  Widget _hostCard(String name, String? avatarUrl) {
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
          AvatarCircle(name: name, url: avatarUrl, size: 40),
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
                Text(
                  widget.room.hostPublicId == null
                      ? 'LIVE'
                      : 'ID ${widget.room.hostPublicId}',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _toggleFollow,
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
    return Container(
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
    );
  }

  Widget _pill(String emoji, String value) {
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
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
            FilterChip(
              label: const SizedBox(
                width: 56,
                child: Center(
                  child: Text('Leave',
                      style: TextStyle(
                          color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              selected: false,
              onSelected: (_) async {
                try {
                  await RoomApi.instance.leaveSeat(_roomId);
                } catch (_) {}
                await _pull();
              },
            ),
          ],
        ],
      );
    }
    if (_room.myRequest != null) {
      return _joinCallBox(
        icon: Icons.hourglass_top_rounded,
        label: 'Requested',
        onTap: () async {
          try {
            await RoomApi.instance.cancelSeatRequest(_roomId);
          } catch (_) {}
          await _pull();
        },
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
            FilterChip(
              label: Icon(
                _speakerOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                color: _speakerOn ? AppColors.gold : Colors.white54,
                size: 22,
              ),
              selected: false,
              onSelected: (_) => _toggleSpeaker(),
            ),
            const SizedBox(width: 8),
            _RoundIcon(
              icon: Icons.card_giftcard_rounded,
              color: AppColors.pink,
              tooltip: 'Send gift to host',
              onTap: () => _giftTo(_hostUserId, widget.room.hostName),
            ),
            const SizedBox(width: 8),
            _RoundIcon(
              icon: Icons.more_horiz_rounded,
              tooltip: 'More',
              onTap: () {},
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
