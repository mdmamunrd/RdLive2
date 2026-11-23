/// One live room card on the Home grid.
/// Matches `GET /v1/rooms?tab=discover|new|follow` response items.
class LiveRoom {
  final String id;
  final String hostName;
  final String countryCode; // ISO-3166 alpha-2, e.g. "BD"
  final String? coverUrl;
  final String? badge; // e.g. "New Star"
  final List<String> audienceAvatars; // up to 3 thumbnails
  final int hostId; // internal user id (gift receiver)
  final int? hostPublicId; // 8-digit id (follow / profile)
  final String? agoraChannel; // Agora channel name of the live room
  final int viewerCount;
  final String mediaMode; // "audio" | "video"
  final int seatCount;
  final bool passwordRequired;

  const LiveRoom({
    required this.id,
    required this.hostName,
    required this.countryCode,
    this.coverUrl,
    this.badge,
    this.audienceAvatars = const [],
    this.hostId = 0,
    this.hostPublicId,
    this.agoraChannel,
    this.viewerCount = 0,
    this.mediaMode = 'audio',
    this.seatCount = 10,
    this.passwordRequired = false,
  });

  factory LiveRoom.fromJson(Map<String, dynamic> j) => LiveRoom(
        id: j['id'].toString(),
        hostName: j['host_name'] as String,
        countryCode: (j['country_code'] as String?) ?? 'BD',
        coverUrl: j['cover_url'] as String?,
        badge: j['badge'] as String?,
        audienceAvatars:
            (j['audience_avatars'] as List?)?.cast<String>() ?? const [],
        hostId: _toInt(j['host_id']),
        hostPublicId: _toIntOrNull(j['host_public_id']),
        agoraChannel: j['agora_channel'] as String?,
        viewerCount: _toInt(j['viewer_count']),
        mediaMode: (j['media_mode'] as String?) ?? 'audio',
        seatCount: (_toInt(j['seat_count']) == 0 ? 10 : _toInt(j['seat_count'])),
        passwordRequired: (j['password_required'] as bool?) ?? false,
      );

  static int _toInt(dynamic v) => v == null ? 0 : int.tryParse(v.toString()) ?? 0;

  static int? _toIntOrNull(dynamic v) =>
      v == null ? null : int.tryParse(v.toString());

  /// Converts "BD" -> 🇧🇩
  String get flagEmoji {
    final cc = countryCode.toUpperCase();
    if (cc.length != 2) return '🏳️';
    return String.fromCharCodes(cc.codeUnits.map((c) => 0x1F1E6 + c - 65));
  }
}
