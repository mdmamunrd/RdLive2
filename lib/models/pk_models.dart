/// Pure data models for PK battles (host vs host).
library;

enum PkSide { a, b } // a = red team, b = blue team

enum PkStatus { ready, running, finished }

class PkHost {
  final String id;
  final String name;
  final String countryCode;
  final String? avatarUrl;

  const PkHost({
    required this.id,
    required this.name,
    this.countryCode = 'BD',
    this.avatarUrl,
  });

  String get flagEmoji {
    final cc = countryCode.toUpperCase();
    if (cc.length != 2) return '🏳️';
    return String.fromCharCodes(cc.codeUnits.map((c) => 0x1F1E6 + c - 65));
  }
}

/// One gift that added points to a side (used for the floating "+500" labels).
class PkGiftEvent {
  final int id;
  final PkSide side;
  final String senderName;
  final int points;

  const PkGiftEvent({
    required this.id,
    required this.side,
    required this.senderName,
    required this.points,
  });
}

/// 12500 -> "12,500"
String formatScore(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
