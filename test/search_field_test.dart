import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixibrowse/src/ui/panes.dart';

void main() {
  testWidgets('clearing the search keeps the cursor in the field',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final other = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    addTearDown(other.dispose);
    final changes = <String>[];

    await tester.pumpWidget(MaterialApp(
      theme: KitTheme.material(KitColors.light),
      home: Scaffold(
        body: Column(
          children: [
            SearchField(
              controller: controller,
              focusNode: focusNode,
              hint: 'Search',
              onChanged: changes.add,
            ),
            Focus(focusNode: other, child: const SizedBox(height: 10)),
          ],
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'numpy');
    await tester.pump();
    // Focus elsewhere, as when the mouse moves to the clear button.
    other.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(changes.last, '');
    expect(focusNode.hasFocus, isTrue);
  });
}
