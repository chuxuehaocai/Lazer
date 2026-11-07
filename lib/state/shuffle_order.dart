import 'dart:math';

/// A shuffled round visits each queue position once. Peeking is stable so the
/// engine prepares the same successor that Next and completion will select.
class ShuffleOrder {
  ShuffleOrder({Random? random}) : _random = random ?? Random();
  final Random _random;
  final List<int> _remaining = [];
  final List<int> _history = [];
  int _historyIndex = -1;
  int _length = 0;
  bool _started = false;

  void reset() {
    _remaining.clear();
    _history.clear();
    _historyIndex = -1;
    _length = 0;
    _started = false;
  }

  int peek(int length, int current) {
    if (length <= 1) return 0;
    _synchronize(length, current);
    if (_historyIndex + 1 < _history.length) {
      return _history[_historyIndex + 1];
    }
    if (_remaining.isEmpty) {
      _remaining.addAll(
        List.generate(length, (index) => index)..shuffle(_random),
      );
      if (!_started) {
        _remaining.remove(current);
        _started = true;
      } else if (_remaining.last == current) {
        // Avoid repeating the last song at the boundary between rounds.
        final swap = _random.nextInt(length - 1);
        final next = _remaining[swap];
        _remaining[swap] = _remaining.last;
        _remaining[_remaining.length - 1] = next;
      }
    }
    return _remaining.last;
  }

  /// Previous retraces the actual listening order without consuming the bag.
  int previous(int length, int current) {
    _synchronize(length, current);
    if (_historyIndex > 0) _historyIndex--;
    return _history[_historyIndex];
  }

  void _synchronize(int length, int current) {
    if (_length != length) reset();
    _length = length;
    if (_historyIndex < 0 || _history[_historyIndex] != current) visit(current);
  }

  void visit(int index) {
    if (_historyIndex >= 0 && _history[_historyIndex] == index) return;
    if (_historyIndex + 1 < _history.length &&
        _history[_historyIndex + 1] == index) {
      _historyIndex++;
      return;
    }
    _remaining.remove(index);
    _history.removeRange(_historyIndex + 1, _history.length);
    _history.add(index);
    _historyIndex = _history.length - 1;
    if (_history.length > 256) {
      _history.removeAt(0);
      _historyIndex--;
    }
  }

  /// A cancelled overlap keeps its prepared source as the next candidate.
  void revisitNext(int index) {
    if (_historyIndex > 0 && _history[_historyIndex] == index) {
      _historyIndex--;
      return;
    }
    _remaining.remove(index);
    _remaining.add(index);
  }
}
