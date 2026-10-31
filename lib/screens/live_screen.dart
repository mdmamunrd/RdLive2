import 'package:flutter/material.dart';
import '../services/agora_service.dart';

class LiveScreen extends StatefulWidget {
  const LiveScreen({Key? key}) : super(key: key);

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  final AgoraService _agoraService = AgoraService();
  final TextEditingController _channelController = TextEditingController();
  bool _isInChannel = false;

  @override
  void dispose() {
    _channelController.dispose();
    _agoraService.leaveChannel();
    super.dispose();
  }

  Future<void> _joinLive() async {
    if (_channelController.text.isEmpty) return;

    try {
      await _agoraService.joinChannel(
        channelName: _channelController.text.trim(),
        uid: 0,
        isBroadcaster: true,
      );
      setState(() {
        _isInChannel = true;
      });
    } catch (e) {
      debugPrint("Error joining channel: $e");
    }
  }

  Future<void> _leaveLive() async {
    try {
      await _agoraService.leaveChannel();
      setState(() {
        _isInChannel = false;
      });
    } catch (e) {
      debugPrint("Error leaving channel: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("RdLive Streaming"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_isInChannel) ...[
              TextField(
                controller: _channelController,
                decoration: const InputDecoration(
                  labelText: "Enter Channel Name",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _joinLive,
                child: const Text("Start Live"),
              ),
            ] else ...[
              const Text(
                "You are live in the channel!",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: _leaveLive,
                child: const Text("Leave Live"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}