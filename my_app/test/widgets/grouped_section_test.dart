import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:paws4thoughtdogs/widgets/grouped_section.dart';

void main() {
  testWidgets('GroupedSection renders ListTiles without framework exceptions',
      (tester) async {
    // Regression: wrapping the rows in a colored Container (instead of a
    // Material) trips "ListTile background color or ink splashes may be
    // invisible" on Flutter 3.44+, which fails the store-screenshot run.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupedSection(
            header: 'Section',
            footer: 'Footer',
            children: [
              ListTile(title: const Text('First'), onTap: () {}),
              ListTile(title: const Text('Second'), onTap: () {}),
              SwitchListTile(
                title: const Text('Toggle'),
                value: true,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('First'), findsOneWidget);

    // Tapping draws ink splashes on the section's own Material.
    await tester.tap(find.text('Second'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    // The rows must sit directly on a Material, not a colored box.
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(GroupedSection),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, isNotNull);
  });
}
