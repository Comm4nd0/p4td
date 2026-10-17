import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/models/day_changes.dart';
import 'package:paws4thoughtdogs/screens/unified_dashboard_screen.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

/// A schedule push opens the dashboard on the day it is about, and that
/// day's Changes section loads for that date — not today's.
class _ChangesFakeDataService extends MockDataService {
  final List<DateTime> changeFetches = [];

  static DailyDogAssignment _assignment(DateTime date) => DailyDogAssignment(
        id: 1,
        dogId: 7,
        dogName: 'Rex',
        staffMemberId: 5,
        staffMemberName: 'Sam',
        ownerName: 'Alex',
        date: date,
        status: AssignmentStatus.assigned,
        dayChanges: const ['EXTRA'],
      );

  @override
  CachedEntry<List<DailyDogAssignment>>? cachedTodayAssignments(DateTime date) =>
      (data: [_assignment(date)], cachedAt: null);

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) async =>
      [_assignment(date ?? DateTime.now())];

  @override
  Future<DayChanges> getDayChanges({DateTime? date}) async {
    final day = date ?? DateTime.now();
    changeFetches.add(day);
    return DayChanges(date: day, weekday: 'Friday', changes: const [
      DayChange(dogId: 8, dogName: 'Bella', kind: DayChange.cancelled, detail: 'Day cancelled'),
    ]);
  }
}

void main() {
  testWidgets('opens on the pushed date with its changes', (tester) async {
    final fake = _ChangesFakeDataService();
    if (getIt.isRegistered<DataService>()) getIt.unregister<DataService>();
    getIt.registerSingleton<DataService>(fake);
    addTearDown(() => getIt.unregister<DataService>());

    final friday = DateTime(2026, 7, 31);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: UnifiedDashboardScreen(isStaff: true, initialDate: friday)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(fake.changeFetches.any((d) => d.year == 2026 && d.month == 7 && d.day == 31), isTrue);
    expect(find.text('Changes vs a normal Friday'), findsOneWidget);
    expect(find.text('Bella'), findsWidgets);
  });
}
