import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/widgets/spotlight_coach.dart';

void main() {
  testWidgets('spotlight points at the target, and Not now / the action fire', (tester) async {
    final key = GlobalKey();
    var acted = 0;
    var dismissed = 0;
    late StateSetter setOverlay;
    var show = true;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          setOverlay = setState;
          return Stack(children: [
            Scaffold(
              body: ListView(children: [
                const SizedBox(height: 300),
                Card(key: key, child: const SizedBox(height: 60, child: Text('Dropped off by owner'))),
                const SizedBox(height: 900),
              ]),
            ),
            if (show)
              Positioned.fill(
                child: SpotlightOverlay(
                  step: SpotlightStep(
                    id: 'drop_off',
                    targetKey: key,
                    title: 'Nobody is meeting the owners',
                    message: 'Two dogs are being dropped off.',
                    actionLabel: 'Name someone',
                    onAction: () async => acted++,
                  ),
                  remaining: 1,
                  onNotNow: () => dismissed++,
                ),
              ),
          ]);
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Nobody is meeting the owners'), findsOneWidget);
    expect(find.text('+1 more'), findsOneWidget);

    await tester.tap(find.text('Name someone'));
    await tester.pumpAndSettle();
    expect(acted, 1);

    // Tapping inside the hole is the action too; tapping the scrim is not.
    await tester.tapAt(tester.getCenter(find.byKey(key)));
    await tester.pumpAndSettle();
    expect(acted, 2);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(acted, 2);

    await tester.tap(find.text('Not now'));
    expect(dismissed, 1);

    setOverlay(() => show = false);
    await tester.pumpAndSettle();
    expect(find.text('Nobody is meeting the owners'), findsNothing);
  });
}
