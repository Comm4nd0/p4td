import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/screens/dashboard/reassign_dogs_dialog.dart';

/// The "Reassign Dogs" quick action: a manager ticks any of the day's dogs
/// and hands them to another driver. The list must be searchable, allow more
/// than one dog, and never offer to move a dog to the person it is already
/// with.
DailyDogAssignment _row(int id, String dog, int staffId, String staff,
        {String status = 'ASSIGNED'}) =>
    DailyDogAssignment.fromJson({
      'id': id,
      'dog': id * 10,
      'dog_name': dog,
      'staff_member': staffId,
      'staff_member_name': staff,
      'owner_name': 'Owner',
      'date': '2026-09-14',
      'status': status,
    });

final _staff = <Map<String, dynamic>>[
  {'id': 1, 'username': 'alice@example.com', 'first_name': 'Alice'},
  {'id': 2, 'username': 'bob@example.com', 'first_name': 'Bob'},
];

final _assignments = [
  _row(11, 'Rex', 1, 'Alice'),
  _row(12, 'Buddy', 1, 'Alice', status: 'PICKED_UP'),
  _row(13, 'Luna', 2, 'Bob'),
];

/// What the dialog returned once it closed; `_closed` says whether it has.
ReassignDogsSelection? _result;
bool _closed = false;

Future<void> _open(
  WidgetTester tester, {
  List<DailyDogAssignment>? assignments,
}) async {
  _result = null;
  _closed = false;
  // Tall enough that every row, both scope radios and the buttons are on
  // screen at once — a tap on an off-screen widget silently does nothing.
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          _result = await showReassignDogsDialog(
            context: context,
            dateLabel: 'Mon 14 Sep',
            weekdayLabel: 'Monday',
            assignments: assignments ?? _assignments,
            staffMembers: _staff,
            availableStaffIds: const {},
          );
          _closed = true;
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _pickStaff(WidgetTester tester, String name) async {
  await tester.tap(find.byType(DropdownButtonFormField<int>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists every dog with its current driver and status',
      (tester) async {
    await _open(tester);

    expect(find.text('Rex'), findsOneWidget);
    expect(find.text('Buddy'), findsOneWidget);
    expect(find.text('Luna'), findsOneWidget);
    expect(find.text('With Alice · Assigned'), findsOneWidget);
    expect(find.text('With Alice · With Team'), findsOneWidget);
    expect(find.text('With Bob · Assigned'), findsOneWidget);
    expect(find.text('0 selected'), findsOneWidget);
  });

  testWidgets('search narrows by dog name or by current staff name',
      (tester) async {
    await _open(tester);

    await tester.enterText(find.byType(TextField), 'lun');
    await tester.pumpAndSettle();
    expect(find.text('Luna'), findsOneWidget);
    expect(find.text('Rex'), findsNothing);
    expect(find.text('Buddy'), findsNothing);

    await tester.enterText(find.byType(TextField), 'alice');
    await tester.pumpAndSettle();
    expect(find.text('Rex'), findsOneWidget);
    expect(find.text('Buddy'), findsOneWidget);
    expect(find.text('Luna'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No dogs match your search.'), findsOneWidget);
  });

  testWidgets('confirm needs both a target and at least one dog',
      (tester) async {
    await _open(tester);

    FilledButton confirm() =>
        tester.widget<FilledButton>(find.byType(FilledButton));
    expect(confirm().onPressed, isNull);

    await tester.tap(find.text('Rex'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(confirm().onPressed, isNull, reason: 'no staff member chosen yet');

    await _pickStaff(tester, 'Bob');
    expect(confirm().onPressed, isNotNull);
    expect(find.text('Reassign 1 dog'), findsOneWidget);
  });

  testWidgets('dogs already with the target cannot be ticked and are dropped',
      (tester) async {
    await _open(tester);

    // Tick Luna (Bob's dog) and Rex, then choose Bob as the target.
    await tester.tap(find.text('Luna'));
    await tester.tap(find.text('Rex'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await _pickStaff(tester, 'Bob');
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Already with Bob'), findsOneWidget);

    final lunaTile = tester.widget<CheckboxListTile>(find.ancestor(
      of: find.text('Luna'),
      matching: find.byType(CheckboxListTile),
    ));
    expect(lunaTile.onChanged, isNull);
  });

  testWidgets('select shown ticks only the dogs that can move',
      (tester) async {
    await _open(tester);
    await _pickStaff(tester, 'Bob');

    await tester.tap(find.text('Select shown'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('Reassign 2 dogs'), findsOneWidget);

    await tester.tap(find.text('Clear shown'));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
  });

  testWidgets('returns the ticked assignments, target and scope',
      (tester) async {
    await _open(tester);

    await _pickStaff(tester, 'Bob');
    await tester.tap(find.text('Rex'));
    await tester.tap(find.text('Buddy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every Monday from now on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reassign 2 dogs'));
    await tester.pumpAndSettle();

    expect(_closed, isTrue);
    expect(_result, isNotNull);
    expect(_result!.assignmentIds, [11, 12]);
    expect(_result!.staffId, 2);
    expect(_result!.scope, AssignmentScope.fromNowOn);
  });

  testWidgets('cancel returns null', (tester) async {
    await _open(tester);
    await _pickStaff(tester, 'Bob');
    await tester.tap(find.text('Rex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_closed, isTrue);
    expect(_result, isNull);
  });
}
