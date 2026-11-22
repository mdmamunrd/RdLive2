import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../services/agora_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_circle.dart';

enum LiveMode { audio, video }

/// Guests who can be on call at the same time (shown on the right side).
const int _kGuestSlots = 5;

class _ChatLine {
  final String name;
  final String text;
  const _ChatLine({required this.name, required this.text});
}

/// Host video live: full screen host camera, 5 guest slots stacked on the
/// right, chat lines, and the bottom bar. Token comes from the Netlify token
/// function. Guests joining arrives with the server.
class HostLiveScreen extends StatefulWidget {
  const HostLiveScreen({super.key, required this.mode});

  final LiveMode mode;

  @override
  State<HostLiveScreen> createState() => _HostLiveScreenState();
}

class _HostLiveScreenState extends State<HostLiveScreen> {
  static const String _tokenUrl =
      'https://graceful-stroopwafel-7d16c1.netlify.app/api/token';

  final TextEditingController _chatCtrl = TextEditingController();
  final List<_ChatLine> _chat = [];

  RtcEngine? _engine;
  String _channel = '';
  bool _joined = false;
  bool _muted = false;
  bool _cameraOn = true;
  bool _ending = false;
  String _error = '';

  /// Remote users who are on call (hosts in the Agora channel), in join order.
  final List<int> _guests = [];

  String get _myName {
    final n = FirebaseAuth.instance.currentUser?.displayName?.trim() ?? '';
    return n.isEmpty ? 'Host' : n;
  }

  String? get _myPhoto => FirebaseAuth.instance.currentUser?.photoURL;

  @override
  void initState() {
    super.initState();
    _cameraOn = widget.mode == LiveMode.video;
    _chat.add(_ChatLine(name: _myName, text: 'You started the live'));
    _start();
  }

  @override
  void dispose() {
    _chatCtrl.dispose();
    _teardown();
    super.dispose();
  }

  // ---- Agora ------------------------------------------------------------------

  Future<void> _teardown() async {
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
      _guests.clear();
    });

    try {
      await _teardown();

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw 'Please sign in again.';
      final channel = 'room_${user.uid}';

      final perms = <Permission>[
        Permission.microphone,
        if (_cameraOn) Permission.camera,
      ];
      final result = await perms.request();
      if (result.values.any((s) => !s.isGranted)) {
        throw 'Permission denied. Please allow '
            '${_cameraOn ? 'microphone and camera' : 'microphone'} in phone settings.';
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
          if (mounted && !_guests.contains(remoteUid)) {
            setState(() => _guests.add(remoteUid));
          }
        },
        onUserOffline: (RtcConnection connection, int remoteUid,
            UserOfflineReasonType reason) {
          if (mounted) setState(() => _guests.remove(remoteUid));
        },
        onTokenPrivilegeWillExpire: (RtcConnection connection, String token) {
          _renewToken();
        },
        onError: (ErrorCodeType err, String msg) {
          if (mounted) setState(() => _error = 'Agora error: $err $msg');
        },
      ));

      await engine.enableAudio();
      await engine.enableVideo(); // also needed to see guests' video
      if (_cameraOn) {
        await engine.startPreview();
      } else {
        await engine.enableLocalVideo(false);
      }
      await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

      await engine.joinChannel(
        token: token,
        channelId: channel,
        uid: 0,
        options: ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          publishMicrophoneTrack: true,
          publishCameraTrack: _cameraOn,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _toggleMute() async {
    final engine = _engine;
    if (engine == null) return;
    final next = !_muted;
    await engine.muteLocalAudioStream(next);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _toggleCamera() async {
    final engine = _engine;
    if (engine == null) return;
    final next = !_cameraOn;
    if (next) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        _toast('Camera permission is needed. Please allow it in phone settings.');
        return;
      }
    }
    await engine.enableLocalVideo(next);
    await engine.muteLocalVideoStream(!next);
    if (next) await engine.startPreview();
    if (mounted) setState(() => _cameraOn = next);
  }

  Future<void> _switchCamera() async {
    await _engine?.switchCamera();
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
        content: const Text('Your live will be closed for everyone.'),
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

  // ---- helpers ----------------------------------------------------------------

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

  void _sendChat(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    setState(() => _chat.add(_ChatLine(name: _myName, text: text)));
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
              leading: Icon(
                _cameraOn ? Icons.videocam_off_rounded : Icons.videocam_rounded,
                color: Colors.white70,
              ),
              title: Text(
                _cameraOn ? 'Turn camera off' : 'Turn camera on',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _toggleCamera();
              },
            ),
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

  // ---- build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.deepPurple,
        body: _joined ? _liveView() : SafeArea(child: _statusView()),
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

  Widget _liveView() {
    final engine = _engine;
    return Stack(
      children: [
        Positioned.fill(child: _hostVideo(engine)),
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black87],
                  stops: [0, .2, .62, 1],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              _topBar(),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Text(
                    _error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                  ),
                ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
                          child: _chatLines(),
                        ),
                      ),
                    ),
                    SizedBox(width: 96, child: _guestColumn(engine)),
                  ],
                ),
              ),
              _bottomBar(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hostVideo(RtcEngine? engine) {
    if (_cameraOn && engine != null) {
      return AgoraVideoView(
        controller: VideoViewController(
          rtcEngine: engine,
          canvas: const VideoCanvas(uid: 0),
        ),
      );
    }
    return Container(
      color: const Color(0xFF1E0B3A),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AvatarCircle(name: _myName, url: _myPhoto, size: 96),
          const SizedBox(height: 12),
          const Text('Camera is off', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  // ---- top bar ----------------------------------------------------------------

  Widget _topBar() {
    return Padding(
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
          _callChip(),
          const SizedBox(width: 8),
          _RoundIcon(
            icon: Icons.close_rounded,
            tooltip: 'End live',
            onTap: _onBack,
          ),
        ],
      ),
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

  /// Number of guests on call (not the audience: the audience count needs the server).
  Widget _callChip() {
    final shown = _guests.length > _kGuestSlots ? _kGuestSlots : _guests.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.headset_mic_rounded, color: Colors.white70, size: 16),
          const SizedBox(width: 4),
          Text(
            'Call $shown/$_kGuestSlots',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ---- right side: 5 guest slots -------------------------------------------------

  Widget _guestColumn(RtcEngine? engine) {
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 8.0;
        const top = 8.0;
        final h = ((c.maxHeight - top - gap * (_kGuestSlots - 1)) / _kGuestSlots)
            .clamp(56.0, 112.0)
            .toDouble();
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.only(top: top, right: 10),
            child: Column(
              children: [
                for (var i = 0; i < _kGuestSlots; i++)
                  Padding(
                    padding: EdgeInsets.only(bottom: i == _kGuestSlots - 1 ? 0 : gap),
                    child: _guestTile(engine, i, h),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _guestTile(RtcEngine? engine, int index, double height) {
    final uid = index < _guests.length ? _guests[index] : null;

    final Widget body;
    if (uid == null || engine == null) {
      body = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toast('Guests can join your call once the server is ready'),
        child: Container(
          color: Colors.black.withValues(alpha: .4),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_rounded, color: Colors.white70, size: 26),
              const SizedBox(height: 2),
              Text(
                '${index + 1}',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      );
    } else {
      body = Stack(
        fit: StackFit.expand,
        children: [
          AgoraVideoView(
            key: ValueKey('guest_$uid'),
            controller: VideoViewController.remote(
              rtcEngine: engine,
              canvas: VideoCanvas(uid: uid),
              connection: RtcConnection(channelId: _channel),
            ),
          ),
          Positioned(
            left: 6,
            bottom: 4,
            child: Text(
              'Guest ${index + 1}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      width: 84,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24, width: 1.2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: body,
      ),
    );
  }

  // ---- chat and bottom bar -------------------------------------------------------

  Widget _chatLines() {
    final lines = _chat.length > 6 ? _chat.sublist(_chat.length - 6) : _chat;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final m in lines)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .35),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${m.name}  ',
                    style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: m.text),
                ],
              ),
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
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
                fillColor: Colors.black.withValues(alpha: .35),
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
            icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            color: _muted ? Colors.redAccent : Colors.white,
            tooltip: 'Microphone',
            onTap: _toggleMute,
          ),
          const SizedBox(width: 8),
          _RoundIcon(
            icon: Icons.cameraswitch_rounded,
            tooltip: 'Switch camera',
            onTap: _switchCamera,
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
    );
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  const _RoundIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .35),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 22),
        ),
      ),
    );
  }
}
