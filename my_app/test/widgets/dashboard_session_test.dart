import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/screens/unified_dashboard_screen.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

final _monday = DateTime(2026, 8, 3);
final _tuesday = DateTime(2026, 8, 4);

DailyDogAssignment _assignment(int id, int staffId, String staffName, DateTime date) =>
    DailyDogAssignment(
      id: id,
      dogId: id,
      dogName: 'Dog $id',
      staffMemberId: staffId,
      staffMemberName: staffName,
      ownerName: 'Alex',
      date: date,
      status: AssignmentStatus.assigned,
    );

/// Sam and Kim both work Monday; Kim has Tuesday off. The neighbouring days'
/// availability answers arrive after Monday's own, as they do on a phone
/// (they are asked for later, by the prefetch).
class _RotaFakeDataService extends MockDataService {
  final List<DateTime> assignmentFetches = [];

  @override
  CachedEntry<List<DailyDogAssignment>>? cachedTodayAssignments(DateTime date) =>
      (data: _roster(date), cachedAt: null);

  List<DailyDogAssignment> _roster(DateTime date) =>
      [_assignment(1, 5, 'Sam', date), _assignment(2, 6, 'Kim', date)];

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) async {
    assignmentFetches.add(date ?? DateTime.now());
    return _roster(date ?? DateTime.now());
  }

  @override
  Future<List<Map<String, dynamic>>> getStaffMembers() async => [
        {'id': 5, 'first_name': 'Sam', 'username': 'sam@example.com'},
        {'id': 6, 'first_name': 'Kim', 'username': 'kim@example.com'},
      ];

  @override
  Future<List<Map<String, dynamic>>> getAvailableStaffForDate(DateTime date) async {
    final selected = date.day == _monday.day;
    if (!selected) await Future<void>.delayed(const Duration(milliseconds: 50));
    return [
      {'id': 5},
      if (date.day != _tuesday.day) {'id': 6},
    ];
  }
}

Future<void> _pump(WidgetTester tester, DataService fake, Widget dashboard) async {
  if (getIt.isRegistered<DataService>()) {
    getIt.unregister<DataService>();
  }
  getIt.registerSingleton<DataService>(fake);
  addTearDown(() => getIt.unregister<DataService>());

  await tester.pumpWidget(MaterialApp(home: Scaffold(body: dashboard)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('DashboardSession', () {
    test('remembers the day for the rest of the day it was chosen on', () {
      final session = DashboardSession();
      expect(session.selectedDate(), isNull);

      session.rememberDate(DateTime(2026, 8, 5, 14), now: DateTime(2026, 8, 3, 9));
      expect(session.selectedDate(now: DateTime(2026, 8, 3, 17)), DateTime(2026, 8, 5));
      // Left open overnight: the board opens on the new today instead.
      expect(session.selectedDate(now: DateTime(2026, 8, 4, 7)), isNull);
    });

    test('keeps what was put off with Not now', () {
      final session = DashboardSession()..spotlightDismissed.add('drop_off');
      expect(session.spotlightDismissed, contains('drop_off'));
    });
  });

  testWidgets("the selected day's time off is not overwritten by the day after's",
      (tester) async {
    await _pump(
      tester,
      _RotaFakeDataService(),
      UnifiedDashboardScreen(isStaff: true, initialDate: _monday),
    );

    expect(find.text('Kim'), findsOneWidget);
    // Kim is off on Tuesday, not today. The prefetch of Tuesday used to
    // write the one shared set last and mark her "(off)" on Monday's board.
    expect(find.text('(off)'), findsNothing);
  });

  testWidgets('a rebuilt dashboard opens on the day its session remembers', (tester) async {
    final fake = _RotaFakeDataService();
    // As HomeScreen holds it across a trip to the Feed tab and back.
    final session = DashboardSession();
    final wednesday = DateTime.now().add(const Duration(days: 2));
    session.rememberDate(wednesday);

    await _pump(tester, fake, UnifiedDashboardScreen(isStaff: true, session: session));

    final first = fake.assignmentFetches.isEmpty ? null : fake.assignmentFetches.first;
    final isWeekend = wednesday.weekday > DateTime.friday;
    if (!isWeekend) {
      expect(first, isNotNull);
      expect(DateTime(first!.year, first.month, first.day),
          DateTime(wednesday.year, wednesday.month, wednesday.day));
    }
    expect(session.selectedDate(),
        DateTime(wednesday.year, wednesday.month, wednesday.day));
  });
}
