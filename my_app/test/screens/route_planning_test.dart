import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/route_plan.dart';
import 'package:paws4thoughtdogs/models/vehicle.dart';
import 'package:paws4thoughtdogs/screens/add_edit_vehicle_screen.dart';
import 'package:paws4thoughtdogs/screens/dashboard/route_plan_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

class _RouteService extends MockDataService {
  Map<int, int?>? plannedWith;
  Map<int, List<int>>? applied;
  ({int id, int? capacity, int? driver})? routingSaved;

  @override
  Future<List<RoutePlanDriver>> getRoutePlanDrivers({DateTime? date}) async => const [
        RoutePlanDriver(staffMemberId: 1, name: 'Alice', vehicleName: 'Big van', capacity: 10, dogsNow: 3, working: true, selected: true),
        RoutePlanDriver(staffMemberId: 2, name: 'Bob', capacity: 4, working: true, selected: true),
        RoutePlanDriver(staffMemberId: 3, name: 'Cara', selected: false),
      ];

  @override
  Future<RoutePlan> planRoutes({required Map<int, int?> drivers, DateTime? date}) async {
    plannedWith = drivers;
    return RoutePlan.fromJson({
      'routes': [
        {
          'staff_member_id': 1, 'staff_member_name': 'Alice', 'capacity': 10, 'load': 2,
          'minutes': 40, 'current_minutes': 70,
          'dogs': [
            {'dog_id': 11, 'name': 'Rex', 'moved': false},
            {'dog_id': 12, 'name': 'Fido', 'moved': false},
          ],
        },
        {
          'staff_member_id': 2, 'staff_member_name': 'Bob', 'capacity': 4, 'load': 1,
          'minutes': 25, 'current_minutes': 20,
          'dogs': [
            {'dog_id': 13, 'name': 'Stray', 'moved': true, 'from_staff_member_name': 'Alice'},
          ],
        },
      ],
      'unplaced': [
        {'dog_id': 14, 'name': 'Lost', 'reason': 'No location on file'},
      ],
      'conflicts': [],
      'over_capacity': [],
    });
  }

  @override
  Future<int> applyRoutePlan({required Map<int, List<int>> routes, DateTime? date}) async {
    applied = routes;
    return 1;
  }

  @override
  Future<List<Map<String, dynamic>>> getStaffMembers() async => [
        {'id': 2, 'first_name': 'Bob', 'username': 'bob'},
      ];

  @override
  Future<Vehicle> updateVehicleRouting(int id, {int? dogCapacity, int? usualDriverId}) async {
    routingSaved = (id: id, capacity: dogCapacity, driver: usualDriverId);
    return Vehicle(id: id, name: 'Van', registration: 'AB1', dogCapacity: dogCapacity, usualDriverId: usualDriverId);
  }
}

void main() {
  late _RouteService service;

  setUp(() {
    service = _RouteService();
    getIt.registerSingleton<DataService>(service);
  });
  tearDown(() => getIt.reset());

  testWidgets('plan routes: ticked drivers and capacities go in, the plan comes out, apply sends it',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: RoutePlanScreen(date: DateTime(2026, 11, 2))));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.textContaining('Big van'), findsOneWidget);

    await tester.tap(find.text('Suggest a plan'));
    await tester.pumpAndSettle();
    expect(service.plannedWith, {1: 10, 2: 4});

    expect(find.textContaining('25 min less than now'), findsOneWidget);
    expect(find.textContaining('1 dog change driver'), findsOneWidget);
    expect(find.textContaining('from Alice'), findsOneWidget);
    expect(find.textContaining('Lost isn\'t on the plan'), findsOneWidget);

    await tester.tap(find.text('Apply plan'));
    await tester.pumpAndSettle();
    expect(service.applied, {1: [11, 12], 2: [13]});
  });

  testWidgets('plan routes: change drivers goes back to the picker without applying', (tester) async {
    await tester.pumpWidget(MaterialApp(home: RoutePlanScreen(date: DateTime(2026, 11, 2))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest a plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change drivers'));
    await tester.pumpAndSettle();
    expect(find.text('Suggest a plan'), findsOneWidget);
    expect(service.applied, isNull);
  });

  testWidgets('vehicle form saves dog capacity and usual driver', (tester) async {
    final vehicle = Vehicle(id: 5, name: 'Van', registration: 'AB1');
    await tester.pumpWidget(MaterialApp(home: AddEditVehicleScreen(vehicle: vehicle)));
    await tester.pumpAndSettle();

    final capacity = find.widgetWithText(TextFormField, 'Dogs it can carry (optional)');
    await tester.scrollUntilVisible(capacity, 200, scrollable: find.byType(Scrollable).first);
    await tester.enterText(capacity, '6');
    await tester.tap(find.text('Nobody'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob').last);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Save Changes'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();
    expect(service.routingSaved, (id: 5, capacity: 6, driver: 2));
  });

  test('optimisation parses and counts the minutes saved', () {
    final r = RouteOptimisation.fromJson({
      'staff_member_id': 1,
      'assignment_ids': [3, 1, 2],
      'dogs': [
        {'assignment_id': 3, 'dog_id': 30, 'name': 'A', 'located': true},
        {'assignment_id': 1, 'dog_id': 10, 'name': 'B', 'located': true},
        {'assignment_id': 2, 'dog_id': 20, 'name': 'C', 'located': false},
      ],
      'current_minutes': 50,
      'optimised_minutes': 38,
      'unlocated': ['C'],
    });
    expect(r.minutesSaved, 12);
    expect(r.dogs.last.located, isFalse);
  });
}
