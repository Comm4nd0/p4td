import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/widgets/form_scroll_body.dart';

/// A long form: one required field at the very top, Submit far below it.
Widget _form(GlobalKey<FormState> key, {required bool lazy, required VoidCallback onSubmit}) {
  final children = <Widget>[
    TextFormField(
      key: const ValueKey('phone'),
      decoration: const InputDecoration(labelText: 'Phone Number'),
      validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
    ),
    const SizedBox(height: 3000),
    ElevatedButton(onPressed: onSubmit, child: const Text('Submit')),
  ];
  return MaterialApp(
    home: Scaffold(
      body: Form(
        key: key,
        child: lazy
            ? ListView(padding: const EdgeInsets.all(16), children: children)
            : FormScrollBody(children: children),
      ),
    ),
  );
}

void main() {
  testWidgets('a required field far above Submit is still validated', (tester) async {
    final key = GlobalKey<FormState>();
    bool? valid;
    await tester.pumpWidget(_form(key, lazy: false, onSubmit: () => valid = validateFormAndReveal(key)));

    await tester.scrollUntilVisible(find.text('Submit'), 500,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    expect(valid, isFalse);
    // ...and the failing field has been brought back into view.
    expect(find.text('Required'), findsOneWidget);
    final field = tester.getRect(find.byKey(const ValueKey('phone')));
    expect(field.top, greaterThanOrEqualTo(0));
    expect(field.bottom, lessThanOrEqualTo(600));
  });

  testWidgets('the lazy ListView it replaces let the blank field through', (tester) async {
    // The bug this widget exists for, pinned so nobody "simplifies" back.
    final key = GlobalKey<FormState>();
    bool? valid;
    await tester.pumpWidget(_form(key, lazy: true, onSubmit: () => valid = key.currentState!.validate()));

    await tester.scrollUntilVisible(find.text('Submit'), 500,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Submit'));
    await tester.pump();

    expect(valid, isTrue, reason: 'the off-screen field had left the Form');
  });

  testWidgets('a valid form passes and nothing scrolls', (tester) async {
    final key = GlobalKey<FormState>();
    bool? valid;
    await tester.pumpWidget(_form(key, lazy: false, onSubmit: () => valid = validateFormAndReveal(key)));

    await tester.enterText(find.byKey(const ValueKey('phone')), '07700 900123');
    await tester.scrollUntilVisible(find.text('Submit'), 500,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    expect(valid, isTrue);
    expect(find.text('Submit'), findsOneWidget);
  });
}
