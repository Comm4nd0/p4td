import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picons/picons.dart';
import 'package:paws4thoughtdogs/widgets/badged_action_icon.dart';

/// The inbox icons beside the bell: a count pill only when there is
/// something unread, capped so a backlog can't widen the AppBar.
void main() {
  Widget build({required int count, VoidCallback? onPressed}) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: [
            BadgedActionIcon(
              icon: PiconsDuotone.chats,
              count: count,
              tooltip: 'Contact Staff',
              onPressed: onPressed ?? () {},
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('no badge at zero', (tester) async {
    await tester.pumpWidget(build(count: 0));
    expect(find.text('0'), findsNothing);
    expect(find.byTooltip('Contact Staff'), findsOneWidget);
  });

  testWidgets('shows the count and fires the callback', (tester) async {
    var taps = 0;
    await tester.pumpWidget(build(count: 4, onPressed: () => taps++));
    expect(find.text('4'), findsOneWidget);
    await tester.tap(find.byTooltip('Contact Staff'));
    expect(taps, 1);
  });

  testWidgets('caps at 99+', (tester) async {
    await tester.pumpWidget(build(count: 250));
    expect(find.text('99+'), findsOneWidget);
    expect(BadgedActionIcon.badgeLabel(99), '99');
    expect(BadgedActionIcon.badgeLabel(100), '99+');
  });

  testWidgets('announces the count to screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(build(count: 2));
    expect(find.bySemanticsLabel('Contact Staff, 2 unread'), findsOneWidget);
    handle.dispose();
  });
}
