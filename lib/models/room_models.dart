/// Pure data models for the live room: users, seats, seat requests, gifts.
/// No Flutter imports, so they can be reused by the realtime layer later.
library;

enum RoomRole { audience, moderator, host }

extension RoomRoleX on RoomRole {
  String get label {
    switch (this) {
      case RoomRole.host:
        return 'Host';
      case RoomRole.moderator:
        return 'Moderator';
      case RoomRole.audience:
        return 'Audience';
    }
  }

  /// host > moderator > audience
  bool outranks(RoomRole other) => index > other.index;
}

class RoomUser {
  final String id;
  final String name;
  final String countryCode; // ISO-3166 alpha-2
  final String? avatarUrl;
  final int level;
  final RoomRole role;

  /// Muted by host/moderator for the whole room (cannot unmute themselves).
  final bool isMuted;

  const RoomUser({
    required this.id,
    required this.name,
    this.countryCode = 'BD',
    this.avatarUrl,
    this.level = 1,
    this.role = RoomRole.audience,
    this.isMuted = false,
  });

  RoomUser copyWith({RoomRole? role, bool? isMuted}) => RoomUser(
        id: id,
        name: name,
        countryCode: countryCode,
        avatarUrl: avatarUrl,
        level: level,
        role: role ?? this.role,
        isMuted: isMuted ?? this.isMuted,
      );

  String get flagEmoji {
    final cc = countryCode.toUpperCase();
    if (cc.length != 2) return '🏳️';
    return String.fromCharCodes(cc.codeUnits.map((c) => 0x1F1E6 + c - 65));
  }
}

enum SeatStatus { empty, occupied, locked }

/// Number of guest seats and grid columns.
enum SeatLayout {
  four(4, 2),
  eight(8, 4);

  const SeatLayout(this.count, this.columns);
  final int count;
  final int columns;
}

/// Audio rooms show circular avatars; video rooms show video tiles.
enum SeatMediaMode { audio, video }

class Seat {
  final int index; // 0-based. Seat 0 is always the host seat.
  final SeatStatus status;
  final RoomUser? user;
  final bool micOn; // the occupant's own mic switch
  final bool cameraOn;

  const Seat({
    required this.index,
    this.status = SeatStatus.empty,
    this.user,
    this.micOn = false,
    this.cameraOn = false,
  });

  factory Seat.empty(int index) => Seat(index: index);
  factory Seat.locked(int index) => Seat(index: index, status: SeatStatus.locked);
  factory Seat.occupied(int index, RoomUser user, {bool mic = true, bool cam = false}) =>
      Seat(index: index, status: SeatStatus.occupied, user: user, micOn: mic, cameraOn: cam);

  bool get isEmpty => status == SeatStatus.empty;
  bool get isLocked => status == SeatStatus.locked;
  bool get isOccupied => status == SeatStatus.occupied;

  /// Mic is really live only if the user switched it on AND was not muted by staff.
  bool get micActive => isOccupied && micOn && !(user?.isMuted ?? false);

  /// Occupied but silent (own switch off or muted by staff).
  bool get isMuted => isOccupied && !micActive;

  Seat withMic(bool on) => Seat(index: index, status: status, user: user, micOn: on, cameraOn: cameraOn);
  Seat withCamera(bool on) => Seat(index: index, status: status, user: user, micOn: micOn, cameraOn: on);
  Seat withUser(RoomUser u) => Seat(index: index, status: status, user: u, micOn: micOn, cameraOn: cameraOn);
}

class SeatRequest {
  final String id;
  final RoomUser user;
  final int? seatIndex; // preferred seat, null = any
  final DateTime requestedAt;

  const SeatRequest({
    required this.id,
    required this.user,
    this.seatIndex,
    required this.requestedAt,
  });

  SeatRequest withSeat(int? index) =>
      SeatRequest(id: id, user: user, seatIndex: index, requestedAt: requestedAt);
}

class GiftOption {
  final int id;
  final String name;
  final String emoji;
  final int price; // coins
  const GiftOption(this.id, this.name, this.emoji, this.price);
}

/// Mock catalogue. Replace with `GET /v1/gifts` later.
const List<GiftOption> kMockGifts = [
  GiftOption(1, 'Rose', '🌹', 10),
  GiftOption(2, 'Heart', '💖', 99),
  GiftOption(3, 'Crown', '👑', 5000),
  GiftOption(4, 'Sports Car', '🏎️', 20000),
  GiftOption(5, 'Dragon', '🐉', 50000),
];
