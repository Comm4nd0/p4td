import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/screens/day_board_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

void main() {
  setUpAll(() {
    // The board resolves DataService lazily for drops/reloads; rendering
    // itself uses only the data passed in, so the mock is never called here.
    if (!getIt.isRegistered<DataService>()) {
      getIt.registerSingleton<DataService>(MockDataService());
    }
  });

  DailyDogAssignment make(int id, int staffId, String staffName, String dog,
      int sortOrder, AssignmentStatus status) {
    return DailyDogAssignment(
      id: id,
      dogId: id,
      dogName: dog,
      staffMemberId: staffId,
      staffMemberName: staffName,
      ownerName: 'Owner',
      date: DateTime(2030, 6, 3),
      status: status,
      sortOrder: sortOrder,
    );
  }

  testWidgets('renders a column per staff member with counts, numbers and progress',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: DayBoardScreen(
        date: DateTime(2030, 6, 3),
        assignments: [
          make(1, 7, 'Sarah', 'Bella', 0, AssignmentStatus.pickedUp),
          make(2, 7, 'Sarah', 'Alfie', 1, AssignmentStatus.assigned),
          make(3, 9, 'James', 'Rex', 0, AssignmentStatus.droppedOff),
        ],
        staffMembers: const [
          {'id': 7, 'username': 'sarah', 'first_name': 'Sarah', 'staff_color': '#112233'},
          {'id': 9, 'username': 'james', 'first_name': 'James', 'staff_color': ''},
        ],
        canAssignDogs: true,
      ),
    ));

    // Columns: Unassigned + both staff.
    expect(find.text('Unassigned'), findsOneWidget);
    expect(find.text('Sarah'), findsOneWidget);
    expect(find.text('James'), findsOneWidget);

    // Dogs with pickup-run numbers (Bella sortOrder 0 → 1, Alfie → 2).
    expect(find.text('Bella'), findsOneWidget);
    expect(find.text('Alfie'), findsOneWidget);
    expect(find.text('Rex'), findsOneWidget);

    // Sarah's progress line: 1 of her 2 pickups collected.
    expect(find.text('1 of 2 collected'), findsOneWidget);
    expect(find.text('1 of 1 collected'), findsOneWidget);

    expect(find.text('No unassigned dogs'), findsOneWidget);
  });

  testWidgets('staff not working that day are hidden unless they have dogs',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: DayBoardScreen(
        date: DateTime(2030, 6, 3),
        assignments: [
          // Priya is off but still has a dog assigned — that's worth seeing.
          make(1, 11, 'Priya', 'Milo', 0, AssignmentStatus.assigned),
        ],
        staffMembers: const [
          {'id': 7, 'username': 'sarah', 'first_name': 'Sarah', 'staff_color': ''},
          {'id': 9, 'username': 'james', 'first_name': 'James', 'staff_color': ''},
          {'id': 11, 'username': 'priya', 'first_name': 'Priya', 'staff_color': ''},
        ],
        // Only Sarah is working today; James and Priya are off.
        availableStaffIds: const {7},
        canAssignDogs: true,
      ),
    ));

    expect(find.text('Sarah'), findsOneWidget); // working → shown
    expect(find.text('James'), findsNothing); // off, no dogs → hidden
    expect(find.text('Priya (off)'), findsOneWidget); // off but has a dog

    // The filter sheet lists hidden columns so they can be shown again.
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    expect(find.text('James (off)'), findsOneWidget);
  });

  testWidgets('density toggle cycles card size and scales the dog cards',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: DayBoardScreen(
        date: DateTime(2030, 6, 3),
        assignments: [make(1, 7, 'Sarah', 'Bella', 0, AssignmentStatus.assigned)],
        staffMembers: const [
          {'id': 7, 'username': 'sarah', 'first_name': 'Sarah', 'staff_color': ''},
        ],
        canAssignDogs: true,
      ),
    ));

    double nameFontSize() =>
        tester.widget<Text>(find.text('Bella')).style!.fontSize!;

    expect(find.byIcon(Icons.density_large), findsOneWidget);
    final comfortable = nameFontSize();

    await tester.tap(find.byIcon(Icons.density_large));
    await tester.pump();
    expect(find.byIcon(Icons.density_medium), findsOneWidget);
    final compact = nameFontSize();
    expect(compact, lessThan(comfortable));

    await tester.tap(find.byIcon(Icons.density_medium));
    await tester.pump();
    expect(find.byIcon(Icons.density_small), findsOneWidget);
    expect(nameFontSize(), lessThan(compact));

    // Cycles back around to comfortable.
    await tester.tap(find.byIcon(Icons.density_small));
    await tester.pump();
    expect(find.byIcon(Icons.density_large), findsOneWidget);
    expect(nameFontSize(), comfortable);
  });

  testWidgets('pinching the board rescales the cards continuously',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: DayBoardScreen(
        date: DateTime(2030, 6, 3),
        assignments: [make(1, 7, 'Sarah', 'Bella', 0, AssignmentStatus.assigned)],
        staffMembers: const [
          {'id': 7, 'username': 'sarah', 'first_name': 'Sarah', 'staff_color': ''},
        ],
        canAssignDogs: true,
      ),
    ));

    double nameFontSize() =>
        tester.widget<Text>(find.text('Bella')).style!.fontSize!;
    final before = nameFontSize();

    // Two-finger pinch-in over the board (clear of the columns): fingers
    // converge vertically so the horizontal column scroll doesn't claim them.
    final g1 = await tester.startGesture(const Offset(900, 300));
    final g2 = await tester.startGesture(const Offset(900, 500));
    await tester.pump();
    await g1.moveBy(const Offset(0, 60));
    await g2.moveBy(const Offset(0, -60));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pump();

    final zoomedOut = nameFontSize();
    expect(zoomedOut, lessThan(before));

    // Pinching out zooms back in (larger cards).
    final g3 = await tester.startGesture(const Offset(900, 390));
    final g4 = await tester.startGesture(const Offset(900, 410));
    await tester.pump();
    await g3.moveBy(const Offset(0, -80));
    await g4.moveBy(const Offset(0, 80));
    await tester.pump();
    await g3.up();
    await g4.up();
    await tester.pump();
    expect(nameFontSize(), greaterThan(zoomedOut));
  });

  testWidgets(
      'long-press drag condenses the board to tiles and hover expands a run',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: DayBoardScreen(
        date: DateTime(2030, 6, 3),
        assignments: [
          make(1, 7, 'Sarah', 'Bella', 0, AssignmentStatus.assigned),
          make(2, 9, 'James', 'Rex', 0, AssignmentStatus.assigned),
          make(3, 9, 'James', 'Poppy', 1, AssignmentStatus.assigned),
        ],
        staffMembers: const [
          {'id': 7, 'username': 'sarah', 'first_name': 'Sarah', 'staff_color': ''},
          {'id': 9, 'username': 'james', 'first_name': 'James', 'staff_color': ''},
        ],
        canAssignDogs: true,
      ),
    ));

    // Long-press Bella and start dragging.
    final gesture = await tester.startGesture(tester.getCenter(find.text('Bella')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();

    // Board condenses into the one-screen tile overview.
    expect(find.textContaining('Drop on a staff member'), findsOneWidget);
    expect(find.text('Unassigned'), findsOneWidget); // unassign tile
    expect(find.text('James'), findsOneWidget);

    // Hold over James's tile until his run expands for precise placement.
    await gesture.moveTo(tester.getCenter(find.text('James')));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('Add to end'), findsOneWidget);
    expect(find.text('Rex'), findsOneWidget);
    expect(find.text('Poppy'), findsOneWidget);

    // Hovering the back bar returns to the tiles.
    await gesture.moveTo(tester.getCenter(find.text('All staff')));
    await tester.pump();
    expect(find.textContaining('Drop on a staff member'), findsOneWidget);

    // Cancel the drag (release over the hint, not a drop target): the board
    // returns to the full columns.
    await gesture.moveTo(tester.getCenter(find.textContaining('Drop on a staff member')));
    await gesture.up();
    await tester.pump();
    expect(find.textContaining('Drop on a staff member'), findsNothing);
    expect(find.text('Bella'), findsOneWidget);
  });
}
