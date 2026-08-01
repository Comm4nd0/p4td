import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/boarding_request.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/screens/dashboard/boarding_section.dart';
import 'package:paws4thoughtdogs/screens/unified_dashboard_screen.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

/// The dashboard doubles as the boarding view, so Saturdays and Sundays are on
/// the date strip — but daycare is strictly Mon–Fri, so those days must not
/// show a roster, and the daycare fetches must not run for them at all.
class _WeekendFakeDataService extends MockDataService {
  final List<DateTime> assignmentFetches = [];

  static DailyDogAssignment _assignment(DateTime date) => DailyDogAssignment(
        id: 1,
        dogId: 7,
        dogName: 'Buddy',
        staffMemberId: 5,
        staffMemberName: 'Sam',
        ownerName: 'Alex',
        date: date,
        status: AssignmentStatus.assigned,
      );

  // Seeding from cache keeps the day loaded on the first frame, sidestepping
  // the skeleton -> loaded transition (see dashboard_warning_failure_test).
  @override
  CachedEntry<List<DailyDogAssignment>>? cachedTodayAssignments(DateTime date) =>
      (data: [_assignment(date)], cachedAt: null);

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) async {
    assignmentFetches.add(date ?? DateTime.now());
    return [_assignment(date ?? DateTime.now())];
  }

  @override
  Future<List<BoardingRequest>> getBoardingRequests() async => [
        BoardingRequest(
          id: 1,
          ownerId: 2,
          ownerName: 'Alex',
          dogIds: const [7],
          dogNames: const ['Buddy'],
          startDate: DateTime(2026, 8, 1),
          endDate: DateTime(2026, 8, 6),
          status: BoardingRequestStatus.approved,
          createdAt: DateTime(2026, 7, 20),
        ),
      ];
}

Future<void> _pump(WidgetTester tester, DataService fake, DateTime date) async {
  if (getIt.isRegistered<DataService>()) {
    getIt.unregister<DataService>();
  }
  getIt.registerSingleton<DataService>(fake);
  addTearDown(() => getIt.unregister<DataService>());

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
        body: UnifiedDashboardScreen(isStaff: true, initialDate: date)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a weekend day shows boarding only, no daycare roster',
      (tester) async {
    final fake = _WeekendFakeDataService();
    await _pump(tester, fake, DateTime(2026, 8, 1)); // a Saturday

    expect(find.text('Boarding only — no daycare at the weekend'), findsOneWidget);
    // None of the daycare surfaces: overview metrics, day board, staff cards.
    expect(find.text('All Dogs'), findsNothing);
    expect(find.text('Day board'), findsNothing);
    expect(find.text('Sam'), findsNothing);
    // ...and the roster was never asked for.
    expect(fake.assignmentFetches.any((d) => d.weekday == DateTime.saturday),
        isFalse);
  });

  testWidgets('a weekday still shows the daycare roster', (tester) async {
    final fake = _WeekendFakeDataService();
    await _pump(tester, fake, DateTime(2026, 7, 31)); // a Friday

    expect(find.text('Boarding only — no daycare at the weekend'), findsNothing);
    expect(find.text('All Dogs'), findsOneWidget);
  });

  testWidgets('each boarding row carries the stay it belongs to',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BoardingSection(
          date: DateTime(2026, 8, 1),
          // Pin the clock: the assertion below is about a day that *isn't*
          // today being named, so it must not depend on when the suite runs.
          // (Unpinned, this failed for real on 1 Aug 2026 and blocked the
          // Android release.)
          now: DateTime(2026, 7, 20),
          boarding: [
            BoardingRequest(
              id: 1,
              ownerId: 2,
              ownerName: 'Alex',
              dogIds: const [7],
              dogNames: const ['Buddy'],
              startDate: DateTime(2026, 8, 1),
              endDate: DateTime(2026, 8, 6),
              status: BoardingRequestStatus.approved,
              createdAt: DateTime(2026, 7, 20),
            ),
          ],
        ),
      ),
    ));

    expect(find.text('Buddy'), findsOneWidget);
    expect(find.text('01/08/26 – 06/08/26'), findsOneWidget);
    // A day other than today is named, so the dates aren't read as "tonight".
    expect(find.text('Boarding Sat 01/08/26'), findsOneWidget);
  });
}
