/// One live room card on the Home grid.
/// Matches `GET /v1/rooms?tab=discover|new|follow` response items.
class LiveRoom {
  final String id;
  final String hostName;
  final String countryCode; // ISO-3166 alpha-2, e.g. "BD"
  final String? coverUrl;
  final String? badge; // e.g. "New Star"
  final List<String> audienceAvatars; // up to 3 thumbnails

  const LiveRoom({
    required this.id,
    required this.hostName,
    required this.countryCode,
    this.coverUrl,
    this.badge,
    this.audienceAvatars = const [],
  });

  factory LiveRoom.fromJson(Map<String, dynamic> j) => LiveRoom(
        id: j['id'].toString(),
        hostName: j['host_name'] as String,
        countryCode: (j['country_code'] as String?) ?? 'BD',
        coverUrl: j['cover_url'] as String?,
        badge: j['badge'] as String?,
        audienceAvatars:
            (j['audience_avatars'] as List?)?.cast<String>() ?? const [],
      );

  /// Converts "BD" -> 🇧🇩
  String get flagEmoji {
    final cc = countryCode.toUpperCase();
    if (cc.length != 2) return '🏳️';
    return String.fromCharCodes(cc.codeUnits.map((c) => 0x1F1E6 + c - 65));
  }
}
