import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/widgets/spotlight_coach.dart';

void main() {
  testWidgets('a failed spotlight action is reported in the bubble and can be retried',
      (tester) async {
    final key = GlobalKey();
    var attempts = 0;

    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [
        Scaffold(
          body: ListView(children: [
            const SizedBox(height: 100),
            Card(key: key, child: const SizedBox(height: 60, child: Text('Changes'))),
            const SizedBox(height: 900),
          ]),
        ),
        Positioned.fill(
          child: SpotlightOverlay(
            step: SpotlightStep(
              id: 'day_changes',
              targetKey: key,
              title: 'Your run changed late',
              message: 'Check the changes below.',
              actionLabel: 'Got it',
              onAction: () async {
                attempts++;
                if (attempts == 1) throw Exception('No signal');
              },
            ),
            onNotNow: () {},
          ),
        ),
      ]),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    // It used to fail without a word: the error went unhandled and the
    // button simply came back.
    expect(tester.takeException(), isNull);
    expect(find.textContaining("didn't go through"), findsOneWidget);
    expect(find.textContaining('No signal'), findsOneWidget);

    // Still there to try again; a success clears the message.
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.textContaining("didn't go through"), findsNothing);
  });
}
