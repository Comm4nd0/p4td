import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/screens/unified_dashboard_screen.dart';

/// The cache holds a saved day and the network hangs — same recipe as the
/// offline test, chosen because it renders a roster deterministically.
class _FakeDataService extends MockDataService {
  final List<DailyDogAssignment> saved;
  _FakeDataService(this.saved);

  @override
  CachedEntry<List<DailyDogAssignment>>? cachedTodayAssignments(DateTime date) =>
      (data: saved, cachedAt: DateTime.now());

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) =>
      Completer<List<DailyDogAssignment>>().future;
}

/// Today when it's a weekday, else the coming Monday — the roster only
/// renders on daycare days.
DateTime _daycareDay() {
  var d = DateTime.now();
  while (d.weekday > DateTime.friday) {
    d = d.add(const Duration(days: 1));
  }
  return d;
}

void main() {
  testWidgets('wide dashboard puts action items beside the roster',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final day = _daycareDay();
    final fake = _FakeDataService([
      DailyDogAssignment(
        id: 1,
        dogId: 7,
        dogName: 'Buddy',
        staffMemberId: 5,
        staffMemberName: 'Sam',
        ownerName: 'Alex',
        date: day,
        status: AssignmentStatus.assigned,
      ),
    ]);
    if (getIt.isRegistered<DataService>()) {
      getIt.unregister<DataService>();
    }
    getIt.registerSingleton<DataService>(fake);
    addTearDown(() => getIt.unregister<DataService>());

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: UnifiedDashboardScreen(isStaff: true, initialDate: day)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Both panes are on screen at once…
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Action Items'), findsOneWidget);

    // …and side by side: the roster on the left, action items in the
    // 400dp-wide right-hand pane.
    final rosterX = tester.getTopLeft(find.text('Sam')).dx;
    final actionsX = tester.getTopLeft(find.text('Action Items')).dx;
    expect(rosterX, lessThan(1200));
    expect(actionsX, greaterThanOrEqualTo(1200));
  });

  testWidgets('narrow dashboard keeps action items below the roster',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final day = _daycareDay();
    final fake = _FakeDataService([
      DailyDogAssignment(
        id: 1,
        dogId: 7,
        dogName: 'Buddy',
        staffMemberId: 5,
        staffMemberName: 'Sam',
        ownerName: 'Alex',
        date: day,
        status: AssignmentStatus.assigned,
      ),
    ]);
    if (getIt.isRegistered<DataService>()) {
      getIt.unregister<DataService>();
    }
    getIt.registerSingleton<DataService>(fake);
    addTearDown(() => getIt.unregister<DataService>());

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: UnifiedDashboardScreen(isStaff: true, initialDate: day)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Single scroll column: the roster renders, and scrolling down the same
    // list reaches the action items.
    expect(find.text('Sam'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Action Items'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Action Items'), findsOneWidget);
  });
}
