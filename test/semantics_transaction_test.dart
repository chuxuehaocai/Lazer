import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/accessibility/semantics_transaction.dart';

Invocation node(int id, List<int> children) => Invocation.method(
  #updateNode,
  [],
  {#id: id, #childrenInTraversalOrder: children},
);

void main() {
  test(
    'detached descendant updates cannot poison AXTree, and reattachment restores them',
    () {
      final transaction = SemanticsTransaction();
      expect(
        transaction.prepare([
          node(0, [1]),
          node(1, [2]),
          node(2, []),
        ]),
        hasLength(3),
      );
      final removal = transaction.prepare([node(0, []), node(2, [])]);
      expect(removal.map((call) => call.namedArguments[#id]), [0]);
      final reattachment = transaction.prepare([
        node(0, [1]),
      ]);
      expect(reattachment.map((call) => call.namedArguments[#id]).toSet(), {
        0,
        1,
        2,
      });
      expect(transaction.prepare([node(2, [])]), hasLength(1));
      transaction.reset();
      expect(transaction.prepare([node(0, [])]), hasLength(1));
    },
  );
}
