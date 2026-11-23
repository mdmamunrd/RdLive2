import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/live_room.dart';
import '../models/room_models.dart';
import 'auth_service.dart';

enum RoomTab { discover, newest, follow }

/// Thrown for non-200 backend answers. `code` matches the backend error code,
/// e.g. "forbidden: not an approved host", "insufficient_coins".
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;
  const ApiException(this.statusCode, this.code, this.message);

  @override
  String toString() => message;
}

class RoomApi {
  RoomApi._();
  static final instance = RoomApi._();

  Map<String, dynamic> _handle(http.Response res) {
    final body = res.body.isEmpty ? '{}' : res.body;
    final data = jsonDecode(body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      String code = 'http_${res.statusCode}';
      String message = 'Request failed (${res.statusCode})';
      if (data is Map<String, dynamic>) {
        code = data['code'] as String? ?? code;
        message = data['message'] as String? ?? message;
      }
      throw ApiException(res.statusCode, code, message);
    }
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> get(String path) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final res = await http
        .get(uri, headers: await AuthService.instance.authHeaders())
        .timeout(ApiConfig.timeout);
    return _handle(res);
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final res = await http
        .post(uri,
            headers: {
              ...await AuthService.instance.authHeaders(),
              if (headers != null) ...headers,
            },
            body: body == null ? null : jsonEncode(body))
        .timeout(ApiConfig.timeout);
    return _handle(res);
  }

  Future<Map<String, dynamic>> delete(String path) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final res = await http
        .delete(uri, headers: await AuthService.instance.authHeaders())
        .timeout(ApiConfig.timeout);
    return _handle(res);
  }

  /// Home feed tabs. Mirrors `GET /v1/rooms?tab=discover|new|follow`.
  Future<List<LiveRoom>> fetchRooms(RoomTab tab) async {
    final name = tab == RoomTab.newest ? 'new' : tab.name;
    final data = await get('/v1/rooms?tab=$name&limit=60');
    final list = (data['rooms'] as List).cast<Map<String, dynamic>>();
    return list.map(LiveRoom.fromJson).toList();
  }

  /// POST /v1/rooms — registers the host's live room so it shows up in
  /// Discover / New feeds. Returns {room_id, agora_channel}.
  Future<Map<String, dynamic>> createRoom({
    required int seatCount,
    required String mediaMode,
    String? title,
  }) =>
      post('/v1/rooms', body: {
        if (title != null && title.isNotEmpty) 'title': title,
        'seat_count': seatCount,
        'media_mode': mediaMode,
      });

  /// POST /v1/rooms/{id}/join — returns the viewer's role in the room.
  Future<String> joinRoom(int roomId, {String? password}) async {
    final data = await post('/v1/rooms/$roomId/join', body: {
      if (password != null && password.isNotEmpty) 'password': password,
    });
    return data['role'] as String? ?? 'audience';
  }

  Future<void> leaveRoom(int roomId) => post('/v1/rooms/$roomId/leave');

  Future<void> endRoom(int roomId) => post('/v1/rooms/$roomId/end');

  /// GET /v1/rooms/{id} — seats, members, room info (after joining).
  Future<Map<String, dynamic>> roomSnapshot(int roomId) =>
      get('/v1/rooms/$roomId');

  /// POST /v1/rooms/{id}/seats/request — {result: "seated"|"pending", seat_index}
  Future<Map<String, dynamic>> requestSeat(int roomId, {int? seatIndex}) =>
      post('/v1/rooms/$roomId/seats/request', body: {
        if (seatIndex != null) 'seat_index': seatIndex,
      });

  Future<void> cancelSeatRequest(int roomId) =>
      delete('/v1/rooms/$roomId/seats/request');

  Future<void> leaveSeat(int roomId) => post('/v1/rooms/$roomId/seats/leave');

  /// GET /v1/wallet — {"coins": n, "diamonds": n}
  Future<int> myCoins() async {
    final data = await get('/v1/wallet');
    return (data['coins'] as num?)?.toInt() ?? 0;
  }

  /// GET /v1/gifts — the real catalogue.
  Future<List<GiftOption>> fetchGifts() async {
    final data = await get('/v1/gifts');
    final list = (data['gifts'] as List).cast<Map<String, dynamic>>();
    return [
      for (final g in list)
        GiftOption(
          (g['id'] as num).toInt(),
          g['name'] as String? ?? 'Gift',
          '🎁',
          (g['price_coins'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// POST /v1/gifts/send — works for every active user (host, guest, any id).
  Future<void> sendGift({
    required int receiverId,
    int? roomId,
    required int giftId,
    int quantity = 1,
  }) {
    final rnd = Random.secure();
    final key =
        'rd${DateTime.now().millisecondsSinceEpoch}${rnd.nextInt(1 << 32)}';
    return post(
      '/v1/gifts/send',
      body: {
        'receiver_id': receiverId,
        if (roomId != null) 'room_id': roomId,
        'gift_id': giftId,
        'quantity': quantity,
      },
      headers: {'Idempotency-Key': key},
    );
  }

  /// POST/DELETE /v1/users/{publicID}/follow
  Future<void> setFollowing(int publicId, bool follow) async {
    if (follow) {
      await post('/v1/users/$publicId/follow');
    } else {
      await delete('/v1/users/$publicId/follow');
    }
  }
}
