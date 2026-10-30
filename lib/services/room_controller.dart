import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/room_models.dart';

/// Local-state controller for a multi-guest room (mock data).
///
/// Every mutating method is a single place to later call the backend / Agora:
/// the UI only talks to this class.
class RoomController extends ChangeNotifier {
  RoomController({
    SeatLayout layout = SeatLayout.eight,
    RoomRole myRole = RoomRole.audience,
    bool seedMockData = true,
    this.autoApproveDemo = true,
  })  : _layout = layout,
        _myRole = myRole {
    _seats = List<Seat>.generate(layout.count, (i) => Seat.empty(i));
    if (seedMockData) _seed();
  }

  // ---- mock identities -------------------------------------------------
  static const meId = 'me';
  static const hostUser = RoomUser(
      id: 'host', name: 'RAFIYA', countryCode: 'SA', level: 52, role: RoomRole.host);
  static const mockUsers = <RoomUser>[
    RoomUser(id: 'u1', name: 'Aisha', countryCode: 'SA', level: 31, role: RoomRole.moderator),
    RoomUser(id: 'u2', name: 'Rahim', countryCode: 'BD', level: 12),
    RoomUser(id: 'u3', name: 'Mansur', countryCode: 'AE', level: 27),
    RoomUser(id: 'u4', name: 'Nila', countryCode: 'BD', level: 9),
    RoomUser(id: 'u5', name: 'Zayan', countryCode: 'BD', level: 17),
    RoomUser(id: 'u6', name: 'Layla', countryCode: 'SA', level: 40),
    RoomUser(id: 'u7', name: 'Tariq', countryCode: 'AE', level: 5),
  ];

  /// Demo only: a pretend host approves your seat request after 3 seconds.
  final bool autoApproveDemo;

  // ---- state -------------------------------------------------------------
  SeatLayout _layout;
  RoomRole _myRole;
  List<Seat> _seats = [];
  List<RoomUser> _participants = [];
  List<SeatRequest> _requests = [];
  final List<RoomUser> _banned = [];
  final List<Timer> _timers = [];
  int _coins = 5000; // mock wallet
  int _requestSeq = 100;
  bool _requireApproval = true;

  final StreamController<String> _messages = StreamController<String>.broadcast();

  /// Short user-facing messages (show them as snackbars).
  Stream<String> get messages => _messages.stream;

  /// Called after a gift was sent (wire to realtime / PK later).
  void Function(RoomUser receiver, GiftOption gift, int quantity)? onGiftSent;

  // ---- getters -----------------------------------------------------------
  SeatLayout get layout => _layout;
  RoomRole get myRole => _myRole;
  List<Seat> get seats => List.unmodifiable(_seats);
  List<RoomUser> get participants => List.unmodifiable(_participants);
  List<SeatRequest> get requests => List.unmodifiable(_requests);
  List<RoomUser> get banned => List.unmodifiable(_banned);
  int get coins => _coins;
  bool get requireApproval => _requireApproval;
  bool get canModerate => _myRole != RoomRole.audience;
  bool get isHost => _myRole == RoomRole.host;

  RoomUser get me => RoomUser(
        id: meId,
        name: 'You',
        countryCode: 'BD',
        level: 8,
        role: _myRole,
        isMuted: _userById(meId)?.isMuted ?? false,
      );

  /// Whoever sits on seat 0 (the real host, or you when acting as host).
  RoomUser? get roomHost => _seats.isEmpty ? null : _seats[0].user;

  Seat? get mySeat => seatOfUser(meId);
  bool get isSeated => mySeat != null;

  SeatRequest? get myRequest {
    for (final r in _requests) {
      if (r.user.id == meId) return r;
    }
    return null;
  }

  Seat? seatOfUser(String userId) {
    for (final s in _seats) {
      if (s.user?.id == userId) return s;
    }
    return null;
  }

  /// Staff may act only on people they outrank (never on themselves).
  bool canActOn(RoomUser target) =>
      canModerate && target.id != meId && _myRole.outranks(target.role);

  // ---- joining / leaving seats ------------------------------------------

  /// Audience: sends a request (or joins directly if approval is off).
  /// Staff: sits immediately.
  void requestToJoin(int index) {
    if (index < 0 || index >= _seats.length) return;
    if (isSeated) {
      _say('You are already on a seat');
      return;
    }
    final seat = _seats[index];
    if (seat.isLocked) {
      _say('Seat ${index + 1} is locked');
      return;
    }
    if (seat.isOccupied) {
      _say('Seat ${index + 1} is taken');
      return;
    }
    if (canModerate || !_requireApproval) {
      _occupy(index, me);
      _say('You joined seat ${index + 1}');
      notifyListeners();
      return;
    }
    if (myRequest != null) {
      _say('Your request is already pending');
      return;
    }
    _requests = [
      ..._requests,
      SeatRequest(
          id: 'r${_requestSeq++}', user: me, seatIndex: index, requestedAt: DateTime.now()),
    ];
    _say('Request sent. Waiting for the host');
    notifyListeners();
    if (autoApproveDemo) _scheduleDemoApproval();
  }

  void cancelRequest() {
    final r = myRequest;
    if (r == null) return;
    _requests = _requests.where((e) => e.id != r.id).toList();
    _say('Request cancelled');
    notifyListeners();
  }

  void leaveSeat() {
    final s = mySeat;
    if (s == null) return;
    if (s.index == 0) {
      _say('The host seat cannot be left');
      return;
    }
    _seats[s.index] = Seat.empty(s.index);
    _say('You left the seat');
    notifyListeners();
  }

  // ---- own mic / camera -------------------------------------------------

  void toggleMic() {
    final s = mySeat;
    if (s == null) {
      _say('Take a seat first');
      return;
    }
    if (me.isMuted) {
      _say('You were muted by the host');
      return;
    }
    _seats[s.index] = s.withMic(!s.micOn);
    notifyListeners();
  }

  void toggleCamera() {
    final s = mySeat;
    if (s == null) {
      _say('Take a seat first');
      return;
    }
    _seats[s.index] = s.withCamera(!s.cameraOn);
    notifyListeners();
  }

  // ---- staff: seat control ---------------------------------------------

  void approveRequest(String requestId, {int? seatIndex}) {
    if (!_requireStaff()) return;
    _approve(requestId, seatIndex);
  }

  void rejectRequest(String requestId) {
    if (!_requireStaff()) return;
    _requests = _requests.where((r) => r.id != requestId).toList();
    notifyListeners();
  }

  void lockSeat(int index) {
    if (!_requireStaff()) return;
    if (index <= 0 || index >= _seats.length) {
      _say('This seat cannot be locked');
      return;
    }
    if (!_seats[index].isEmpty) {
      _say('Remove the guest before locking');
      return;
    }
    _seats[index] = Seat.locked(index);
    _requests = [
      for (final r in _requests) r.seatIndex == index ? r.withSeat(null) : r,
    ];
    _say('Seat ${index + 1} locked');
    notifyListeners();
  }

  void unlockSeat(int index) {
    if (!_requireStaff()) return;
    if (index < 0 || index >= _seats.length || !_seats[index].isLocked) return;
    _seats[index] = Seat.empty(index);
    _say('Seat ${index + 1} unlocked');
    notifyListeners();
  }

  void removeFromSeat(String userId) {
    final u = _userById(userId);
    if (u == null || !_requireCanAct(u)) return;
    final s = seatOfUser(userId);
    if (s == null) return;
    _seats[s.index] = Seat.empty(s.index);
    _say('${u.name} was moved off the seat');
    notifyListeners();
  }

  set requireApproval(bool value) {
    _requireApproval = value;
    notifyListeners();
  }

  void setLayout(SeatLayout next) {
    if (next == _layout) return;
    final old = _seats;
    final fresh = List<Seat>.generate(
        next.count, (i) => i < old.length ? old[i] : Seat.empty(i));
    // Guests on seats that disappear move to a free seat if there is one.
    for (var i = next.count; i < old.length; i++) {
      final s = old[i];
      if (!s.isOccupied) continue;
      final free = fresh.indexWhere((e) => e.isEmpty);
      if (free != -1) {
        fresh[free] = Seat.occupied(free, s.user!, mic: s.micOn, cam: s.cameraOn);
      }
    }
    _seats = fresh;
    _layout = next;
    _requests = [
      for (final r in _requests)
        (r.seatIndex != null && r.seatIndex! >= next.count) ? r.withSeat(null) : r,
    ];
    notifyListeners();
  }

  // ---- staff: moderation -------------------------------------------------

  void muteUser(String userId) => _setMuted(userId, true);
  void unmuteUser(String userId) => _setMuted(userId, false);

  /// Removes the user from the room. They may come back (unlike a ban).
  void kickUser(String userId) {
    final u = _userById(userId);
    if (u == null || !_requireCanAct(u)) return;
    _removeEverywhere(userId);
    _say('${u.name} was removed from the room');
    notifyListeners();
  }

  /// Removes the user and blocks them from re-entering this room.
  void banUser(String userId) {
    final u = _userById(userId);
    if (u == null || !_requireCanAct(u)) return;
    _removeEverywhere(userId);
    _banned.add(u.copyWith(isMuted: false));
    _say('${u.name} was banned from the room');
    notifyListeners();
  }

  void unbanUser(String userId) {
    if (!_requireStaff()) return;
    final before = _banned.length;
    _banned.removeWhere((u) => u.id == userId);
    if (_banned.length != before) {
      _say('User can join the room again');
      notifyListeners();
    }
  }

  // ---- gifts (mock wallet) ---------------------------------------------

  bool sendGift(String receiverId, GiftOption gift, {int quantity = 1}) {
    final receiver = _userById(receiverId);
    if (receiver == null || receiverId == meId) return false;
    final total = gift.price * quantity;
    if (total > _coins) {
      _say('Not enough coins. Recharge to send this gift');
      return false;
    }
    _coins -= total;
    _say('Sent ${gift.emoji} ${gift.name} to ${receiver.name}');
    onGiftSent?.call(receiver, gift, quantity);
    notifyListeners();
    return true;
  }

  // ---- demo helper: act as another role --------------------------------

  void setMyRole(RoomRole role) {
    if (role == _myRole) return;
    final wasHost = _myRole == RoomRole.host;
    final s = mySeat;
    if (s != null) _seats[s.index] = Seat.empty(s.index);
    _requests = _requests.where((r) => r.user.id != meId).toList();
    _myRole = role;
    _participants = [
      if (role != RoomRole.host) hostUser,
      ..._participants.where((u) => u.id != meId && u.id != hostUser.id),
      me,
    ];
    if (role == RoomRole.host) {
      _seats[0] = Seat.occupied(0, me, mic: true, cam: true);
    } else if (wasHost) {
      _seats[0] = Seat.occupied(0, hostUser, mic: true, cam: true);
    }
    _say('You are now ${role.label}');
    notifyListeners();
  }

  // ---- internals ----------------------------------------------------------

  void _seed() {
    final hostIsMe = _myRole == RoomRole.host;
    _participants = [
      if (!hostIsMe) hostUser,
      me,
      ...mockUsers,
    ];
    _seats[0] = Seat.occupied(0, hostIsMe ? me : hostUser, mic: true, cam: true);
    _seatMock(1, mockUsers[0], mic: true, cam: true); // Aisha (moderator)
    _seatMock(2, mockUsers[1], mic: false, cam: false); // Rahim, mic off
    if (_seats.length > 3) _seats[3] = Seat.locked(3);
    _seatMock(5, mockUsers[2], mic: true, cam: false); // Mansur (8-seat only)
    _requests = [
      SeatRequest(
          id: 'r1',
          user: mockUsers[3],
          seatIndex: null,
          requestedAt: DateTime.now().subtract(const Duration(minutes: 2))),
      SeatRequest(
          id: 'r2',
          user: mockUsers[4],
          seatIndex: _seats.length > 4 ? 4 : null,
          requestedAt: DateTime.now().subtract(const Duration(seconds: 40))),
    ];
  }

  void _seatMock(int index, RoomUser user, {required bool mic, required bool cam}) {
    if (index >= _seats.length) return;
    _seats[index] = Seat.occupied(index, user, mic: mic, cam: cam);
  }

  void _occupy(int index, RoomUser user) {
    _seats[index] = Seat.occupied(index, user, mic: true, cam: false);
  }

  bool _approve(String requestId, int? seatIndex) {
    SeatRequest? req;
    for (final r in _requests) {
      if (r.id == requestId) req = r;
    }
    if (req == null) return false;
    var target = seatIndex ?? req.seatIndex;
    if (target == null || target >= _seats.length || !_seats[target].isEmpty) {
      target = _seats.indexWhere((s) => s.isEmpty);
    }
    if (target == -1) {
      _say('No free seats');
      return false;
    }
    _requests = _requests.where((r) => r.id != requestId).toList();
    _occupy(target, req.user);
    _say('${req.user.name} joined seat ${target + 1}');
    notifyListeners();
    return true;
  }

  void _scheduleDemoApproval() {
    late final Timer t;
    t = Timer(const Duration(seconds: 3), () {
      _timers.remove(t);
      final r = myRequest;
      if (r != null) _approve(r.id, null);
    });
    _timers.add(t);
  }

  void _setMuted(String userId, bool muted) {
    final u = _userById(userId);
    if (u == null || !_requireCanAct(u)) return;
    _replaceUser(u.copyWith(isMuted: muted));
    _say(muted ? '${u.name} was muted' : '${u.name} was unmuted');
    notifyListeners();
  }

  void _replaceUser(RoomUser updated) {
    _participants = [for (final p in _participants) p.id == updated.id ? updated : p];
    _seats = [for (final s in _seats) s.user?.id == updated.id ? s.withUser(updated) : s];
  }

  void _removeEverywhere(String userId) {
    _participants = _participants.where((p) => p.id != userId).toList();
    _seats = [
      for (final s in _seats) s.user?.id == userId ? Seat.empty(s.index) : s,
    ];
    _requests = _requests.where((r) => r.user.id != userId).toList();
  }

  RoomUser? _userById(String id) {
    for (final p in _participants) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool _requireStaff() {
    if (canModerate) return true;
    _say('Only the host or moderators can do this');
    return false;
  }

  bool _requireCanAct(RoomUser target) {
    if (!_requireStaff()) return false;
    if (canActOn(target)) return true;
    _say('You cannot do this to ${target.name}');
    return false;
  }

  void _say(String message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _messages.close();
    super.dispose();
  }
}
