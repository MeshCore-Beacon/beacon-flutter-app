import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens every folded section on screen, so a test can read what is inside.
Future<void> openFolds(WidgetTester tester) async {
  final keys = find
      .byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('fold-'),
      )
      .evaluate()
      .map((e) => e.widget.key!)
      .toList();
  for (final key in keys) {
    await tester.ensureVisible(find.byKey(key));
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }
}
