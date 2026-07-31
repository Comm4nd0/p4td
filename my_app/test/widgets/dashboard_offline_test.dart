import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/connectivity_status.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/screens/unified_dashboard_screen.dart';
import 'package:paws4thoughtdogs/widgets/skeleton_loaders.dart';

/// Offline scenario: the cache holds a saved day, the network never answers.
class _OfflineFakeDataService extends MockDataService {
  final List<DailyDogAssignment> saved;
  final DateTime savedAt;
  _OfflineFakeDataService(this.saved, this.savedAt);

  @override
  CachedEntry<List<DailyDogAssignment>>? cachedTodayAssignments(DateTime date) =>
      (data: saved, cachedAt: savedAt);

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) =>
      // A dead low-signal connection: the request just hangs.
      Completer<List<DailyDogAssignment>>().future;
}

/// Today when it's a weekday, else the coming Monday. The dashboard shows no
/// roster at all on a Saturday or Sunday (daycare is Mon–Fri; weekend days are
/// on the strip for boarding only), so a test about the roster has to open on
/// a daycare day whatever day the suite happens to run.
DateTime _daycareDay() {
  var d = DateTime.now();
  while (d.weekday > DateTime.friday) {
    d = d.add(const Duration(days: 1));
  }
  return d;
}

void main() {
  testWidgets(
      'dashboard renders the saved day instantly while the network hangs',
      (tester) async {
    final day = _daycareDay();
    final assignment = DailyDogAssignment(
      id: 1,
      dogId: 7,
      dogName: 'Buddy',
      staffMemberId: 5,
      staffMemberName: 'Sam',
      ownerName: 'Alex',
      date: day,
      status: AssignmentStatus.assigned,
    );
    final fake = _OfflineFakeDataService(
        [assignment], DateTime.now().subtract(const Duration(minutes: 30)));
    if (getIt.isRegistered<DataService>()) {
      getIt.unregister<DataService>();
    }
    getIt.registerSingleton<DataService>(fake);
    ConnectivityStatus().reportNetworkFailure(); // app knows it's offline
    addTearDown(() {
      ConnectivityStatus().reportSuccess();
      getIt.unregister<DataService>();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: UnifiedDashboardScreen(isStaff: true, initialDate: day)),
    ));
    // A frame or two, NOT pumpAndSettle: the hung network request never
    // completes and the skeleton shimmer (if wrongly shown) never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Cache-seeded content is on screen — no skeleton while the fetch hangs.
    expect(find.byType(ListTileSkeletonList), findsNothing);
    expect(find.text('Sam'), findsOneWidget);

    // The staleness banner makes the saved data unmissable.
    expect(find.textContaining('Saved data from'), findsOneWidget);
  });
}
