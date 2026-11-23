import 'dart:collection';
import 'dart:ui' as ui;

/// Keeps one semantics batch inside the tree the engine already has.
///
/// Flutter can serialize a dirty descendant after its parent was detached by
/// an animated switch. AXTree rejects the whole batch if it contains that
/// orphan, and a rejected batch leaves the engine's tree inconsistent, so every
/// later batch fails the same way: one bad delta turns into one error per frame
/// for the rest of the run. That is why this filter exists at all.
///
/// The filter may only ever *remove* updates from a batch. A retained payload is
/// kept to prove ancestry (the update format carries parent-to-child lists, not
/// parent ids), never to put a node back: re-sending a node the engine could not
/// attach before reproduces exactly the rejected batch, because the parent's
/// children list that would tell the engine where the node belongs is not part
/// of the batch it is replayed into.
class SemanticsTransaction {
  final LinkedHashMap<int, Invocation> _nodes = LinkedHashMap();

  /// Root of the framework's semantics tree. A batch that carries it describes
  /// the tree from the top instead of delta-updating it.
  static const int _rootId = 0;

  /// Batches that re-described the tree from the root. Every one of them is a
  /// point where nothing retained before it is trustworthy.
  int baselines = 0;

  /// Updates dropped because the engine has no place for them.
  int orphanUpdates = 0;

  void reset() {
    _nodes.clear();
  }

  List<Invocation> prepare(Iterable<Invocation> updates) {
    final List<Invocation> batch = updates.toList();
    if (batch.isEmpty) return batch;
    // Bound the map before recording, so a batch is never the thing that gets
    // trimmed and every payload it brings survives for the next walk.
    _trim();
    final Set<int> dirty = <int>{};
    for (final Invocation update in batch) {
      final int id = update.namedArguments[#id] as int;
      _nodes.remove(id);
      _nodes[id] = update;
      dirty.add(id);
    }
    // A root-carrying batch is either a full serialization or the first batch of
    // a fresh isolate after a hot restart — where the engine still holds the
    // previous isolate's tree while this one starts with an empty map. Payloads
    // retained before it describe nodes that no longer exist, so they must not
    // decide reachability again.
    if (dirty.contains(_rootId)) {
      _nodes.removeWhere((int id, _) => !dirty.contains(id));
      baselines++;
    }
    final Set<int>? reachable = _reachableFromRoot();
    // Without a root to walk from there is no evidence of an orphan, and the
    // framework's own batch is self-consistent by construction: pass it through
    // untouched rather than guessing which of its nodes the engine can place.
    if (reachable == null) return batch;
    final List<Invocation> result = <Invocation>[
      for (final Invocation update in batch)
        if (reachable.contains(update.namedArguments[#id] as int)) update,
    ];
    orphanUpdates += batch.length - result.length;
    return result;
  }

  Set<int>? _reachableFromRoot() {
    if (!_nodes.containsKey(_rootId)) return null;
    final Set<int> reachable = <int>{};
    final List<int> pending = <int>[_rootId];
    while (pending.isNotEmpty) {
      final int id = pending.removeLast();
      if (!reachable.add(id)) continue;
      final Invocation? node = _nodes[id];
      // A referenced node we hold no payload for makes the whole walk a guess,
      // and guessing would drop live controls: an unknown payload means "fall
      // back to the framework's batch", exactly as before.
      if (node == null) return null;
      pending.addAll(
        (node.namedArguments[#childrenInTraversalOrder] as Iterable<int>?) ??
            const <int>[],
      );
    }
    return reachable;
  }

  /// Retained payloads only answer "where did this node hang last time", which
  /// recent nodes answer. Anything older is stale enough to mislead the walk —
  /// except the root, which every walk starts from.
  void _trim() {
    const int limit = 512;
    while (_nodes.length > limit) {
      final int oldest = _nodes.keys.firstWhere(
        (int id) => id != _rootId,
        orElse: () => _rootId,
      );
      if (oldest == _rootId) break;
      _nodes.remove(oldest);
    }
  }
}

class TransactionalSemanticsBuilder implements ui.SemanticsUpdateBuilder {
  TransactionalSemanticsBuilder(this.transaction);
  final SemanticsTransaction transaction;
  final ui.SemanticsUpdateBuilder _native = ui.SemanticsUpdateBuilder();
  final List<Invocation> _updates = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      _updates.add(invocation);
      return null;
    }
    return super.noSuchMethod(invocation);
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => _native.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );

  @override
  ui.SemanticsUpdate build() {
    // A builder is unusable after build(), but one recorded node that outlived
    // its builder would be replayed into the next tree with a stale id: drain the
    // list instead of leaving it to the framework's allocation order.
    final List<Invocation> updates = List<Invocation>.of(_updates);
    _updates.clear();
    for (final update in transaction.prepare(updates)) {
      Function.apply(
        _native.updateNode,
        update.positionalArguments,
        update.namedArguments,
      );
    }
    return _native.build();
  }
}
