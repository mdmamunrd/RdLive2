import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../services/agora_service.dart';
import '../theme/app_theme.dart';

enum LiveMode { audio, video }

class HostLiveScreen extends StatefulWidget {
  const HostLiveScreen({super.key, required this.mode});

  final LiveMode mode;

  @override
  State<HostLiveScreen> createState() => _HostLiveScreenState();
}

class _HostLiveScreenState extends State<HostLiveScreen> {
  static const String _tokenUrl =
      'https://graceful-stroopwafel-7d16c1.netlify.app/api/token';

  RtcEngine? _engine;
  String _channel = '';
  bool _busy = false;
  bool _joined = false;
  bool _muted = false;
  String _error = '';
  final Set<int> _remoteUids = {};

  bool get _isVideo => widget.mode == LiveMode.video;

  String get _myChannel {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return 'room_$uid';
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

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
    if (_busy) return;

    setState(() {
      _busy = true;
      _error = '';
      _joined = false;
      _remoteUids.clear();
    });

    try {
      await _teardown();

      final channel = _myChannel;
      if (channel == 'room_') throw 'Please sign in again.';

      final perms = <Permission>[
        Permission.microphone,
        if (_isVideo) Permission.camera,
      ];
      final result = await perms.request();
      if (result.values.any((s) => !s.isGranted)) {
        throw 'Permission denied. Please allow '
            '${_isVideo ? 'microphone and camera' : 'microphone'} in phone settings.';
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
      if (_isVideo) {
        await engine.enableVideo();
        await engine.startPreview();
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
          publishCameraTrack: _isVideo,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _end() async {
    await _teardown();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _toggleMute() async {
    final engine = _engine;
    if (engine == null) return;
    final next = !_muted;
    await engine.muteLocalAudioStream(next);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _switchCamera() async {
    await _engine?.switchCamera();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepPurple,
      body: SafeArea(
        child: _joined ? _liveView() : _setupView(),
      ),
    );
  }

  Widget _setupView() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(_isVideo ? Icons.videocam_rounded : Icons.mic_rounded,
              size: 56, color: AppColors.gold),
          const SizedBox(height: 12),
          Text(
            _isVideo ? 'Video Live' : 'Audio Party',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Your room: $_myChannel',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 28),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _busy ? null : _start,
            child: Text(_busy ? 'Connecting...' : 'Start Live'),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _liveView() {
    final engine = _engine;
    return Stack(
      children: [
        Positioned.fill(
          child: (_isVideo && engine != null)
              ? AgoraVideoView(
                  controller: VideoViewController(
                    rtcEngine: engine,
                    canvas: const VideoCanvas(uid: 0),
                  ),
                )
              : _audioBackdrop(),
        ),
        if (_isVideo && engine != null && _remoteUids.isNotEmpty)
          Positioned(
            top: 12,
            right: 12,
            child: Column(
              children: [
                for (final uid in _remoteUids.take(4))
                  Container(
                    width: 96,
                    height: 128,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white54),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: AgoraVideoView(
                      controller: VideoViewController.remote(
                        rtcEngine: engine,
                        canvas: VideoCanvas(uid: uid),
                        connection: RtcConnection(channelId: _channel),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'LIVE  •  ${_remoteUids.length} joined',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
        if (_error.isNotEmpty)
          Positioned(
            top: 56,
            left: 12,
            right: 12,
            child: Text(
              _error,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _roundButton(
                icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                color: Colors.white24,
                onTap: _toggleMute,
              ),
              const SizedBox(width: 20),
              _roundButton(
                icon: Icons.call_end_rounded,
                color: Colors.red,
                onTap: _end,
                size: 64,
              ),
              if (_isVideo) ...[
                const SizedBox(width: 20),
                _roundButton(
                  icon: Icons.cameraswitch_rounded,
                  color: Colors.white24,
                  onTap: _switchCamera,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _audioBackdrop() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white12,
              border: Border.all(color: AppColors.gold, width: 3),
            ),
            child: Icon(
              _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              size: 56,
              color: AppColors.gold,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'You are live',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    double size = 52,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}
