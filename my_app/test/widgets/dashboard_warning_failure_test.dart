import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/screens/unified_dashboard_screen.dart';

/// The unassigned-dogs and compatibility-conflict loaders used to end in
/// `catch (_) {}`, and both banners hide themselves when their list is empty.
/// A failed load therefore rendered *identically* to "all clear" — the two
/// warnings that stop a dog being left behind and stop incompatible dogs
/// sharing a van.
class _FailingWarningsDataService extends MockDataService {
  final bool failUnassigned;
  final bool failConflicts;
  _FailingWarningsDataService({
    this.failUnassigned = false,
    this.failConflicts = false,
  });

  static DailyDogAssignment _assignment(DateTime? date) => DailyDogAssignment(
        id: 1,
        dogId: 7,
        dogName: 'Buddy',
        staffMemberId: 5,
        staffMemberName: 'Sam',
        ownerName: 'Alex',
        date: date ?? DateTime.now(),
        status: AssignmentStatus.assigned,
      );

  // Seed from cache so the day renders loaded on the first frame. Going through
  // the skeleton -> loaded AnimatedSwitcher transition trips a pre-existing
  // unbounded-viewport assertion in the widget test harness (its layoutBuilder
  // stacks both children inside the scroll view), which is unrelated to what
  // these tests cover. dashboard_offline_test.dart seeds the same way.
  @override
  CachedEntry<List<DailyDogAssignment>>? cachedTodayAssignments(DateTime date) =>
      (data: [_assignment(date)], cachedAt: null);

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) async =>
      [_assignment(date)];

  @override
  Future<List<Dog>> getUnassignedDogs({DateTime? date}) async {
    if (failUnassigned) throw Exception('Failed to load unassigned dogs');
    return [];
  }

  @override
  Future<List<CompatibilityConflict>> getCompatibilityConflicts({DateTime? date}) async {
    if (failConflicts) throw Exception('Failed to load conflicts');
    return [];
  }
}

Future<void> _pumpDashboard(WidgetTester tester, MockDataService fake) async {
  if (getIt.isRegistered<DataService>()) {
    getIt.unregister<DataService>();
  }
  getIt.registerSingleton<DataService>(fake);
  addTearDown(() => getIt.unregister<DataService>());

  await tester.pumpWidget(const MaterialApp(
    home: Scaffold(body: UnifiedDashboardScreen(isStaff: true)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a failed unassigned-dogs load is visible, not silent',
      (tester) async {
    await _pumpDashboard(tester, _FailingWarningsDataService(failUnassigned: true));
    expect(find.textContaining("Unassigned dogs — couldn't check"), findsOneWidget);
  });

  testWidgets('a failed compatibility-conflicts load is visible, not silent',
      (tester) async {
    await _pumpDashboard(tester, _FailingWarningsDataService(failConflicts: true));
    expect(find.textContaining("Grouping conflicts — couldn't check"), findsOneWidget);
  });

  testWidgets('a clean day shows neither placeholder', (tester) async {
    await _pumpDashboard(tester, _FailingWarningsDataService());
    expect(find.textContaining("couldn't check"), findsNothing);
  });
}
