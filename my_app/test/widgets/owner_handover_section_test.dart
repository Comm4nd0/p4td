import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/constants/app_colors.dart';
import 'package:paws4thoughtdogs/models/owner_handover_status.dart';
import 'package:paws4thoughtdogs/screens/dashboard/owner_handover_section.dart';

/// Two dogs dropped off by their owner with nobody down to meet them, one dog
/// collected by its owner with Sam handing it back.
const _status = OwnerHandoverStatus(
  dropOff: OwnerHandoverLegStatus(
    leg: OwnerHandoverLeg.dropOff,
    count: 2,
    dogs: [
      OwnerHandoverDog(dogId: 1, dogName: 'Buddy', time: '08:30'),
      OwnerHandoverDog(dogId: 2, dogName: 'Coco'),
    ],
  ),
  collection: OwnerHandoverLegStatus(
    leg: OwnerHandoverLeg.collection,
    count: 1,
    dogs: [OwnerHandoverDog(dogId: 3, dogName: 'Dot', time: '17:00')],
    staffMemberId: 5,
    staffMemberName: 'Sam',
  ),
);

const _staff = [
  {'id': 5, 'username': 'sam@example.com', 'first_name': 'Sam'},
  {'id': 6, 'username': 'jo@example.com', 'first_name': 'Jo'},
];

Future<List<(OwnerHandoverLeg, int)>> _pump(
  WidgetTester tester, {
  OwnerHandoverStatus? status = _status,
  Set<int> available = const {5, 6},
}) async {
  final calls = <(OwnerHandoverLeg, int)>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: OwnerHandoverSection(
        status: status,
        staffMembers: _staff,
        availableStaffIds: available,
        onAssign: (leg, staffId) async => calls.add((leg, staffId)),
      ),
    ),
  ));
  await tester.pump();
  return calls;
}

Color? _outline(WidgetTester tester, String label) {
  final card = tester.widget<Card>(
      find.ancestor(of: find.text(label), matching: find.byType(Card)).first);
  final side = (card.shape as RoundedRectangleBorder).side;
  return side == BorderSide.none ? null : side.color;
}

void main() {
  testWidgets('unassigned leg is outlined red, assigned leg green',
      (tester) async {
    await _pump(tester);
    expect(find.text('Dropped off by owner'), findsOneWidget);
    expect(find.text('Collected by owner'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Assign staff'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(_outline(tester, 'Dropped off by owner'), AppColors.error);
    expect(_outline(tester, 'Collected by owner'), AppColors.success);
  });

  testWidgets('a leg with no dogs has no outline and does not need staff',
      (tester) async {
    const quiet = OwnerHandoverStatus(
      dropOff: OwnerHandoverLegStatus(leg: OwnerHandoverLeg.dropOff, count: 3),
      collection:
          OwnerHandoverLegStatus(leg: OwnerHandoverLeg.collection, count: 0),
    );
    await _pump(tester, status: quiet);
    expect(_outline(tester, 'Dropped off by owner'), AppColors.error);
    expect(_outline(tester, 'Collected by owner'), isNull);
    expect(find.text('No dogs'), findsOneWidget);
  });

  testWidgets('hidden until loaded and when nobody is handing over',
      (tester) async {
    await _pump(tester, status: null);
    expect(find.text('Dropped off by owner'), findsNothing);
    const empty = OwnerHandoverStatus(
      dropOff: OwnerHandoverLegStatus(leg: OwnerHandoverLeg.dropOff, count: 0),
      collection:
          OwnerHandoverLegStatus(leg: OwnerHandoverLeg.collection, count: 0),
    );
    await _pump(tester, status: empty);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('tapping a card lists the dogs and assigns the picked staff',
      (tester) async {
    final calls = await _pump(tester);
    await tester.tap(find.text('Dropped off by owner'));
    await tester.pumpAndSettle();

    expect(find.text('2 dogs dropped off by owner'), findsOneWidget);
    expect(find.text('Buddy'), findsOneWidget);
    expect(find.text('08:30'), findsOneWidget);
    expect(find.text('Coco'), findsOneWidget);
    expect(find.text('Who is meeting the owners?'), findsOneWidget);

    // Nobody picked yet: the button waits for a choice.
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);

    await tester.tap(find.text('Jo'));
    await tester.pump();
    await tester.tap(find.text('Assign'));
    await tester.pumpAndSettle();

    expect(calls, [(OwnerHandoverLeg.dropOff, 6)]);
  });

  testWidgets('re-picking the same staff member is not re-sent, others are',
      (tester) async {
    final calls = await _pump(tester);
    await tester.tap(find.text('Collected by owner'));
    await tester.pumpAndSettle();
    expect(find.text('Change staff member'), findsOneWidget);
    await tester.tap(find.text('Change staff member'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await tester.tap(find.text('Collected by owner'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jo'));
    await tester.pump();
    await tester.tap(find.text('Change staff member'));
    await tester.pumpAndSettle();
    expect(calls, [(OwnerHandoverLeg.collection, 6)]);
  });

  testWidgets('staff not working that day are marked and sorted last',
      (tester) async {
    await _pump(tester, available: {6});
    await tester.tap(find.text('Dropped off by owner'));
    await tester.pumpAndSettle();
    expect(find.text('Not working today'), findsOneWidget);
    // The collection card behind the sheet also says "Sam": look only at
    // the picker's rows.
    Finder tile(String name) => find.ancestor(
        of: find.text(name), matching: find.byType(RadioListTile<int>));
    final jo = tester.getTopLeft(tile('Jo'));
    final sam = tester.getTopLeft(tile('Sam'));
    expect(jo.dy, lessThan(sam.dy));
  });
}
