import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';

class AgoraService {
  static const String appId = "0cdec08a1d1a490a8a3a61ea431476c3";

  RtcEngine? _engine;
  bool _isInitialized = false;

  Future<void> initAgora() async {
    if (_isInitialized) return;

    await [Permission.microphone, Permission.camera].request();

    final engine = createAgoraRtcEngine();
    await engine.initialize(const RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
    ));

    _engine = engine;
    _isInitialized = true;
  }

  Future<void> joinChannel({
    required String channelName,
    required int uid,
    required bool isBroadcaster,
    String token = "",
  }) async {
    await initAgora();
    final engine = _engine!;

    await engine.enableAudio();
    if (isBroadcaster) {
      await engine.enableVideo();
      await engine.startPreview();
    }

    await engine.joinChannel(
      token: token,
      channelId: channelName,
      uid: uid,
      options: ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
        clientRoleType: isBroadcaster
            ? ClientRoleType.clientRoleBroadcaster
            : ClientRoleType.clientRoleAudience,
        publishMicrophoneTrack: isBroadcaster,
        publishCameraTrack: isBroadcaster,
        autoSubscribeAudio: true,
        autoSubscribeVideo: true,
      ),
    );
  }

  Future<void> leaveChannel() async {
    final engine = _engine;
    if (engine == null) return;
    await engine.leaveChannel();
    await engine.release();
    _engine = null;
    _isInitialized = false;
  }
}
