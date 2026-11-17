/// An unacknowledged native destroy may already have freed its pointer. Keep
/// one owner alive instead of retrying that pointer or accumulating new engines.
class NativeEngineOwnershipBudget {
  Object? _owner;
  Object? _active;

  bool get blocked => _owner != null;
  bool get busy => _active != null;

  /// Reserve synchronously before the creator's first await (including spawn).
  Future<T?> admit<T>(Future<T?> Function(Object reservation) create) {
    if (blocked || busy) return Future<T?>.value(null);
    final reservation = Object();
    _active = reservation;
    return Future<T?>.sync(
      () => create(reservation),
    ).whenComplete(() => release(reservation));
  }

  void claim(Object owner, {Object? reservation}) {
    if (!blocked && reservation != null && identical(_active, reservation)) {
      _active = owner;
      return;
    }
    if (blocked || busy) {
      throw StateError('a native engine owner is already active');
    }
    _active = owner;
  }

  void release(Object owner) {
    if (identical(_active, owner) && !blocked) _active = null;
  }

  void retain(Object owner) {
    if (_active != null && !identical(_active, owner)) {
      throw StateError('another native engine owns the budget');
    }
    if (_owner != null && !identical(_owner, owner)) {
      throw StateError('an unconfirmed native owner is already retained');
    }
    _owner = owner;
  }
}
