import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/day_changes.dart';
import 'package:paws4thoughtdogs/screens/dashboard/day_changes_section.dart';
import 'package:paws4thoughtdogs/screens/staff_dog_detail_screen.dart';

DayChange _change(String name, String kind, {bool late = false, bool mine = true}) => DayChange(
      dogId: name.hashCode,
      dogName: name,
      kind: kind,
      detail: kind == DayChange.cancelled ? 'Day cancelled' : 'Extra day',
      usualStaffId: 1,
      usualStaffName: 'Jo',
      changedByName: 'Sam',
      mine: mine,
      late: late,
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('hidden when nothing differs', (tester) async {
    await tester.pumpWidget(_wrap(DayChangesSection(
      changes: DayChanges(date: DateTime(2026, 10, 22), weekday: 'Wednesday', changes: const []),
    )));
    expect(find.textContaining('Changes vs'), findsNothing);
  });

  testWidgets('lists the changes and offers Got it for a late one on my run', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(_wrap(DayChangesSection(
      changes: DayChanges(date: DateTime(2026, 10, 22), weekday: 'Wednesday', changes: [
        _change('Bella', DayChange.cancelled, late: true),
        _change('Rex', DayChange.extra, mine: false),
      ]),
      onConfirm: () async => confirmed = true,
    )));
    expect(find.text('Changes vs a normal Wednesday'), findsOneWidget);
    expect(find.text('Bella'), findsOneWidget);
    expect(find.text('Rex'), findsOneWidget);
    expect(find.text('Late'), findsOneWidget);
    await tester.tap(find.textContaining('Got it'));
    await tester.pump();
    expect(confirmed, isTrue);
  });

  testWidgets('no Got it when nothing late is on my run', (tester) async {
    await tester.pumpWidget(_wrap(DayChangesSection(
      changes: DayChanges(date: DateTime(2026, 10, 22), weekday: 'Wednesday', changes: [
        _change('Bella', DayChange.cancelled),
      ]),
      onConfirm: () async {},
    )));
    expect(find.textContaining('Got it'), findsNothing);
  });

  testWidgets('not-today card names the dog and why', (tester) async {
    await tester.pumpWidget(_wrap(NotTodayCard(change: _change('Bella', DayChange.cancelled))));
    expect(find.text('Bella'), findsOneWidget);
    expect(find.text('Not today — Day cancelled · by Sam'), findsOneWidget);
  });

  testWidgets('tapping a dog hands its change to onDogTap', (tester) async {
    DayChange? tapped;
    await tester.pumpWidget(_wrap(DayChangesSection(
      changes: DayChanges(
        date: DateTime(2026, 10, 22),
        weekday: 'Wednesday',
        changes: [_change('Bella', DayChange.extra)],
      ),
      onDogTap: (c) => tapped = c,
    )));
    await tester.tap(find.text('Bella'));
    expect(tapped?.dogName, 'Bella');
  });
}
