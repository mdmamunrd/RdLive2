import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/live_room.dart';
import 'auth_service.dart';

enum RoomTab { discover, newest, follow }

class RoomApi {
  RoomApi._();
  static final instance = RoomApi._();

  Future<List<LiveRoom>> fetchRooms(RoomTab tab) async {
    if (ApiConfig.useMockData) {
      await Future.delayed(const Duration(milliseconds: 400));
      return _mock;
    }
    final name = tab == RoomTab.newest ? 'new' : tab.name;
    final res = await http
        .get(
          Uri.parse('${ApiConfig.baseUrl}/v1/rooms?tab=$name'),
          headers: await AuthService.instance.authHeaders(),
        )
        .timeout(ApiConfig.timeout);
    if (res.statusCode != 200) {
      throw Exception('Failed to load rooms (${res.statusCode})');
    }
    final list = (jsonDecode(res.body)['rooms'] as List).cast<Map<String, dynamic>>();
    return list.map(LiveRoom.fromJson).toList();
  }

  // Placeholder data: replace by API. Image URLs are null -> gradient placeholder.
  static const _mock = <LiveRoom>[
    LiveRoom(id: '1', hostName: 'RAFIYA', countryCode: 'SA', badge: 'New Star'),
    LiveRoom(id: '2', hostName: 'KKAGENCY', countryCode: 'BD', badge: 'New Star'),
    LiveRoom(id: '3', hostName: 'DustoAgency', countryCode: 'BD'),
    LiveRoom(id: '4', hostName: 'BD✓DON', countryCode: 'BD', badge: 'New Star'),
    LiveRoom(id: '5', hostName: 'MansStar', countryCode: 'AE'),
    LiveRoom(id: '6', hostName: 'Saiyan', countryCode: 'BD', badge: 'New Star'),
  ];
}
