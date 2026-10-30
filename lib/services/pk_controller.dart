import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/pk_models.dart';

/// Local-state PK battle engine (mock data).
///
/// To go live, keep the UI as is and feed real events into [addScore]
/// (e.g. from the realtime `gift` event of the room) instead of
/// [simulateGifts].
class PkController extends ChangeNotifier {
  PkController({
    required this.hostA,
    required this.hostB,
    Duration duration = const Duration(minutes: 5),
    this.simulateGifts = true,
    Random? random,
  })  : _total = duration.inSeconds,
        _remaining = duration.inSeconds,
        _random = random ?? Random();

  final PkHost hostA;
  final PkHost hostB;

  /// When true, random mock gifts arrive while the battle runs.
  final bool simulateGifts;

  final int _total;
  final Random _random;

  int _remaining;
  int _scoreA = 0;
  int _scoreB = 0;
  int _eventSeq = 0;
  PkStatus _status = PkStatus.ready;
  PkGiftEvent? _lastGiftA;
  PkGiftEvent? _lastGiftB;
  Timer? _clock;
  Timer? _mockGifts;

  PkStatus get status => _status;
  int get scoreA => _scoreA;
  int get scoreB => _scoreB;
  int get remaining => _remaining;
  int get total => _total;
  PkGiftEvent? get lastGiftA => _lastGiftA;
  PkGiftEvent? get lastGiftB => _lastGiftB;

  bool get isDraw => _status == PkStatus.finished && _scoreA == _scoreB;

  /// Winning side once finished; null while running or on a draw.
  PkSide? get winner {
    if (_status != PkStatus.finished || _scoreA == _scoreB) return null;
    return _scoreA > _scoreB ? PkSide.a : PkSide.b;
  }

  /// Red share of the total, clamped so both colours stay visible.
  double get ratioA {
    final t = _scoreA + _scoreB;
    if (t == 0) return 0.5;
    return (_scoreA / t).clamp(0.08, 0.92).toDouble();
  }

  /// "04:59"
  String get clock {
    final m = (_remaining ~/ 60).toString().padLeft(2, '0');
    final s = (_remaining % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void start() {
    if (_status == PkStatus.running) return;
    if (_status == PkStatus.finished) _resetState();
    _status = PkStatus.running;
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    if (simulateGifts) {
      _mockGifts?.cancel();
      _mockGifts = Timer.periodic(const Duration(milliseconds: 1100), (_) => _simulate());
    }
    notifyListeners();
  }

  /// One second passes. Public so tests (and a server-synced clock) can drive it.
  void tick() {
    if (_status != PkStatus.running) return;
    _remaining -= 1;
    if (_remaining <= 0) {
      _remaining = 0;
      finish();
    } else {
      notifyListeners();
    }
  }

  /// Ends the battle now (time up or host pressed End).
  void finish() {
    if (_status != PkStatus.running) return;
    _stopTimers();
    _status = PkStatus.finished;
    notifyListeners();
  }

  void addScore(PkSide side, int points, {String sender = 'Fan'}) {
    if (_status != PkStatus.running || points <= 0) return;
    if (side == PkSide.a) {
      _scoreA += points;
    } else {
      _scoreB += points;
    }
    final ev = PkGiftEvent(id: ++_eventSeq, side: side, senderName: sender, points: points);
    if (side == PkSide.a) {
      _lastGiftA = ev;
    } else {
      _lastGiftB = ev;
    }
    notifyListeners();
  }

  void reset() {
    _resetState();
    notifyListeners();
  }

  void rematch() {
    _resetState();
    start();
  }

  void _resetState() {
    _stopTimers();
    _scoreA = 0;
    _scoreB = 0;
    _remaining = _total;
    _lastGiftA = null;
    _lastGiftB = null;
    _status = PkStatus.ready;
  }

  void _stopTimers() {
    _clock?.cancel();
    _mockGifts?.cancel();
    _clock = null;
    _mockGifts = null;
  }

  static const _names = ['Aisha', 'Rahim', 'Mansur', 'Nila', 'Zayan', 'Layla', 'Tariq'];
  static const _points = [10, 50, 100, 500, 1000];

  void _simulate() {
    final side = _random.nextDouble() < 0.5 ? PkSide.a : PkSide.b;
    addScore(
      side,
      _points[_random.nextInt(_points.length)],
      sender: _names[_random.nextInt(_names.length)],
    );
  }

  @override
  void dispose() {
    _stopTimers();
    super.dispose();
  }
}
