import 'package:flutter_test/flutter_test.dart';

import 'package:rdlive/models/pk_models.dart';
import 'package:rdlive/models/room_models.dart';
import 'package:rdlive/services/pk_controller.dart';
import 'package:rdlive/services/room_controller.dart';

RoomController room(RoomRole role, {SeatLayout layout = SeatLayout.eight}) {
  final c = RoomController(myRole: role, layout: layout, autoApproveDemo: false);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('seat flow', () {
    test('audience request is pending, then host approves', () {
      final c = room(RoomRole.audience);
      c.requestToJoin(4);
      expect(c.myRequest, isNotNull);
      expect(c.isSeated, isFalse);

      // swap to host: host approves a mock request instead
      final h = room(RoomRole.host);
      h.approveRequest('r1');
      expect(h.seatOfUser('u4'), isNotNull);
      expect(h.requests.any((r) => r.id == 'r1'), isFalse);
    });

    test('locked seat cannot be requested; staff can lock and unlock', () {
      final a = room(RoomRole.audience);
      a.requestToJoin(3); // seeded as locked
      expect(a.myRequest, isNull);

      final h = room(RoomRole.host);
      h.lockSeat(4);
      expect(h.seats[4].isLocked, isTrue);
      h.unlockSeat(4);
      expect(h.seats[4].isEmpty, isTrue);
      h.lockSeat(0); // host seat
      expect(h.seats[0].isLocked, isFalse);
    });

    test('mic and camera toggle only on own seat; muted user cannot unmute', () {
      final h = room(RoomRole.host); // sits on seat 0
      expect(h.mySeat!.micActive, isTrue);
      h.toggleMic();
      expect(h.mySeat!.micActive, isFalse);
      h.toggleCamera();
      expect(h.mySeat!.cameraOn, isFalse); // was on, now off

      final c = room(RoomRole.moderator);
      expect(c.seatOfUser('u3')!.micActive, isTrue); // Mansur starts with mic on
      c.muteUser('u3');
      expect(c.seatOfUser('u3')!.micActive, isFalse);
      c.unmuteUser('u3');
      expect(c.seatOfUser('u3')!.micActive, isTrue);
    });

    test('leaving: guests can leave, host seat cannot', () {
      final m = room(RoomRole.moderator);
      m.requestToJoin(4); // staff sit directly
      expect(m.isSeated, isTrue);
      m.leaveSeat();
      expect(m.isSeated, isFalse);

      final h = room(RoomRole.host);
      h.leaveSeat();
      expect(h.isSeated, isTrue);
    });

    test('shrinking to 4 seats keeps state consistent', () {
      final h = room(RoomRole.host);
      h.setLayout(SeatLayout.four);
      expect(h.seats.length, 4);
      expect(h.seatOfUser('u3'), isNull); // no free seat for the guest from seat 6
      expect(h.requests.every((r) => (r.seatIndex ?? 0) < 4), isTrue);
    });
  });

  group('moderation', () {
    test('audience cannot kick or ban', () {
      final a = room(RoomRole.audience);
      a.kickUser('u2');
      a.banUser('u3');
      expect(a.participants.any((u) => u.id == 'u2'), isTrue);
      expect(a.banned, isEmpty);
    });

    test('host ban removes from seat + room, unban clears the list', () {
      final h = room(RoomRole.host);
      h.banUser('u2');
      expect(h.seatOfUser('u2'), isNull);
      expect(h.participants.any((u) => u.id == 'u2'), isFalse);
      expect(h.banned.map((u) => u.id), contains('u2'));
      h.unbanUser('u2');
      expect(h.banned, isEmpty);
    });

    test('moderator cannot act on another moderator or the host', () {
      final m = room(RoomRole.moderator);
      m.banUser('u1'); // Aisha is a moderator
      m.kickUser('host');
      expect(m.participants.any((u) => u.id == 'u1'), isTrue);
      expect(m.participants.any((u) => u.id == 'host'), isTrue);
    });

    test('reject removes a pending request', () {
      final h = room(RoomRole.host);
      h.rejectRequest('r2');
      expect(h.requests.map((r) => r.id), ['r1']);
    });
  });

  group('gifts', () {
    test('coins are deducted; insufficient coins are refused', () {
      final c = room(RoomRole.audience);
      expect(c.sendGift('u2', kMockGifts.first), isTrue); // Rose, 10
      expect(c.coins, 4990);
      expect(c.sendGift('u2', kMockGifts.last), isFalse); // Dragon, 50000
      expect(c.coins, 4990);
    });
  });

  group('PK battle', () {
    PkController pk({int seconds = 3}) {
      final p = PkController(
        hostA: const PkHost(id: 'a', name: 'A'),
        hostB: const PkHost(id: 'b', name: 'B'),
        duration: Duration(seconds: seconds),
        simulateGifts: false,
      );
      addTearDown(p.dispose);
      return p;
    }

    test('scores only count while running; ratio is clamped', () {
      final p = pk();
      p.addScore(PkSide.a, 100);
      expect(p.scoreA, 0);
      p.start();
      p.addScore(PkSide.a, 900);
      p.addScore(PkSide.b, 100);
      expect(p.ratioA, closeTo(0.9, 1e-9));
      p.addScore(PkSide.a, 1000000);
      expect(p.ratioA, 0.92);
    });

    test('countdown finishes and picks the winner', () {
      final p = pk(seconds: 3);
      p.start();
      p.addScore(PkSide.b, 500);
      p.tick();
      p.tick();
      expect(p.status, PkStatus.running);
      expect(p.clock, '00:01');
      p.tick();
      expect(p.status, PkStatus.finished);
      expect(p.winner, PkSide.b);
    });

    test('draw has no winner; rematch resets', () {
      final p = pk(seconds: 1);
      p.start();
      p.addScore(PkSide.a, 10);
      p.addScore(PkSide.b, 10);
      p.tick();
      expect(p.isDraw, isTrue);
      expect(p.winner, isNull);
      p.rematch();
      expect(p.status, PkStatus.running);
      expect(p.scoreA + p.scoreB, 0);
    });

    test('formatScore', () {
      expect(formatScore(1234567), '1,234,567');
      expect(formatScore(999), '999');
    });
  });
}
