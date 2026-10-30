import 'dart:collection';
import 'dart:ui' as ui;

/// Flutter can serialize a dirty descendant after its parent was detached by
/// an animated switch. AXTree rejects the whole batch if it contains that
/// orphan. Keep the delta connected, retaining payloads for quick reattachment.
class SemanticsTransaction {
  final LinkedHashMap<int, Invocation> _nodes = LinkedHashMap();
  Set<int> _published = {};
  int orphanUpdates = 0;
  int restoredNodes = 0;

  void reset() {
    _nodes.clear();
    _published.clear();
  }

  List<Invocation> prepare(Iterable<Invocation> updates) {
    final dirty = <int>{};
    for (final update in updates) {
      final id = update.namedArguments[#id] as int;
      _nodes.remove(id);
      _nodes[id] = update;
      dirty.add(id);
    }
    final reachable = <int>{};
    final pending = <int>[0];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!reachable.add(id)) continue;
      final node = _nodes[id];
      if (node == null) {
        // Preserve the original behaviour if a completely unknown payload is
        // referenced; this path must not silently discard a live control.
        return updates.toList();
      }
      pending.addAll(
        (node.namedArguments[#childrenInTraversalOrder] as Iterable<int>?) ??
            const [],
      );
    }
    final result = [
      for (final id in reachable)
        if (dirty.contains(id) || !_published.contains(id)) _nodes[id]!,
    ];
    orphanUpdates += dirty.difference(reachable).length;
    restoredNodes += reachable.difference(_published).difference(dirty).length;
    _published = reachable;
    final retired = _nodes.keys.where((id) => !reachable.contains(id)).toList();
    for (final id in retired.take(
      retired.length > 512 ? retired.length - 512 : 0,
    )) {
      _nodes.remove(id);
    }
    return result;
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
    for (final update in transaction.prepare(_updates)) {
      Function.apply(
        _native.updateNode,
        update.positionalArguments,
        update.namedArguments,
      );
    }
    return _native.build();
  }
}
