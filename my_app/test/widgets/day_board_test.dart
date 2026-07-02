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
}
