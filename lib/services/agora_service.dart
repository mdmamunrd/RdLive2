import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';

class AgoraService {
  static const String appId = "0cdec08a1d1a490a8a3a61ea431476c3"; 
  static const String appCertificate = "53283547e62f402b9ef67ad653ad7a4d";

  late RtcEngine _engine;
  bool _isInitialized = false;

  Future<void> initAgora() async {
    if (_isInitialized) return;

    await [Permission.microphone, Permission.camera].request();

    _engine = createAgoraRtcEngine();
    await _engine.initialize(const RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
    ));

    _isInitialized = true;
  }

  Future<void> joinChannel({
    required String channelName,
    required int uid,
    required bool isBroadcaster,
  }) async {
    await initAgora();

    await _engine.setClientRole(
      role: isBroadcaster 
          ? ClientRoleType.clientRoleBroadcaster 
          : ClientRoleType.clientRoleAudience,
    );

    await _engine.enableVideo();
    await _engine.startPreview();

    await _engine.joinChannel(
      token: "",
      channelId: channelName,
      uid: uid,
      options: const ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
      ),
    );
  }

  Future<void> leaveChannel() async {
    await _engine.leaveChannel();
    await _engine.release();
    _isInitialized = false;
  }
}