import 'dart:math';

/// A shuffled round visits each queue position once. Peeking is stable so the
/// engine prepares the same successor that Next and completion will select.
class ShuffleOrder {
  ShuffleOrder({Random? random}) : _random = random ?? Random();
  final Random _random;
  final List<int> _remaining = [];
  int _length = 0;
  bool _started = false;

  void reset() {
    _remaining.clear();
    _length = 0;
    _started = false;
  }

  int peek(int length, int current) {
    if (length <= 1) return 0;
    if (_length != length) reset();
    _length = length;
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

  void visit(int index) => _remaining.remove(index);

  /// A cancelled overlap keeps its prepared source as the next candidate.
  void revisitNext(int index) {
    _remaining.remove(index);
    _remaining.add(index);
  }
}
