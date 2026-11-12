import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/day_off_request.dart';
import 'package:paws4thoughtdogs/screens/dashboard/action_items_section.dart';
import 'package:paws4thoughtdogs/screens/staff_availability_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/widgets/assignment_action_dialogs.dart';

class _Server extends MockDataService {
  final List<int> approved = [];
  late List<DayOffRequest> all = [
    DayOffRequest(
      id: 7,
      staffMemberId: 2,
      staffMemberName: 'Sam',
      date: DateTime.now().add(const Duration(days: 10)),
      createdAt: DateTime.now(),
    ),
  ];

  @override
  Future<List<DayOffRequest>> getAllDayOffRequests() async => all;

  @override
  Future<DayOffRequest> approveDayOffRequest(int requestId) async {
    approved.add(requestId);
    all = [];
    return super.approveDayOffRequest(requestId);
  }
}

/// A manager must be able to find and decide the team's day-off requests:
/// the queue opens first on the Time Off tab, and the dashboard has a row
/// for it.
void main() {
  late _Server server;

  setUp(() async {
    await getIt.reset();
    server = _Server();
    getIt.registerSingleton<DataService>(server);
  });

  testWidgets('a manager lands on the team queue and can approve', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: StaffAvailabilityScreen(
        canAssignDogs: false,
        canManageStaff: true,
        initialTab: StaffAvailabilityScreen.timeOffTab,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Team Requests to Approve'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    // The queue sits above the manager's own Request Day Off button.
    expect(
      tester.getTopLeft(find.text('Team Requests to Approve')).dy,
      lessThan(tester.getTopLeft(find.text('Request Day Off')).dy),
    );

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(server.approved, [7]);
    expect(find.text('Sam'), findsNothing);
  });

  testWidgets('other staff see no team queue', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: StaffAvailabilityScreen(
        canAssignDogs: false,
        initialTab: StaffAvailabilityScreen.timeOffTab,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Request Day Off'), findsOneWidget);
    expect(find.text('Team Requests to Approve'), findsNothing);
  });

  testWidgets('the dashboard row shows for managers only', (tester) async {
    var opened = 0;
    Widget build({required bool manager}) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ActionItemsSection(
                pendingRequestCount: 0,
                unresolvedQueryCount: 0,
                unreadInquiryCount: 0,
                pendingBookingFormCount: 0,
                pendingProfileChangeCount: 0,
                pendingBoardingCount: 0,
                unresolvedDefectCount: 0,
                unresolvedVehicleDefectCount: 0,
                openIncidentCount: 0,
                dogHealthCount: 0,
                pendingDayOffCount: 2,
                canViewInquiries: false,
                canManageRequests: false,
                canManageStaff: manager,
                onOpenPendingRequests: () {},
                onOpenQueries: () {},
                onOpenInquiries: () {},
                onOpenBookingForms: () {},
                onOpenProfileChanges: () {},
                onOpenBoardingRequests: () {},
                onOpenDefects: () {},
                onOpenIncidents: () {},
                onOpenDogHealth: () {},
                onOpenDayOffRequests: () => opened++,
              ),
            ),
          ),
        );

    await tester.pumpWidget(build(manager: false));
    expect(find.text('Day Off Requests'), findsNothing);

    await tester.pumpWidget(build(manager: true));
    expect(find.text('Day Off Requests'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.text('Day Off Requests'));
    expect(opened, 1);
  });

  group('assigning to someone who is off', () {
    const staff = [
      {'id': 1, 'first_name': 'Alex', 'username': 'alex'},
      {'id': 2, 'first_name': 'Sam', 'username': 'sam'},
    ];

    Future<int?> Function() open(WidgetTester tester, {required String pick}) {
      int? result = -1;
      return () async {
        await tester.pumpWidget(MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await pickStaffMemberFromList(
                  context,
                  title: 'Assign Bella',
                  staffMembers: staff,
                  availableStaffIds: const {1}, // Sam (2) is off
                );
              },
              child: const Text('open'),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(pick).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Assign'));
        await tester.pumpAndSettle();
        return result;
      };
    }

    testWidgets('warns, and Assign anyway pushes it through', (tester) async {
      await open(tester, pick: 'Sam')();
      expect(find.text('Sam is off'), findsOneWidget);
      await tester.tap(find.text('Assign anyway'));
      await tester.pumpAndSettle();
      expect(find.text('Sam is off'), findsNothing);
      expect(find.text('Assign Bella'), findsNothing); // picker closed with Sam
    });

    testWidgets('Cancel goes back to the picker with nothing assigned', (tester) async {
      await open(tester, pick: 'Sam')();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.text('Sam is off'), findsNothing);
      expect(find.text('Assign Bella'), findsOneWidget);
    });

    testWidgets('no warning for someone who is working', (tester) async {
      final result = await open(tester, pick: 'Alex')();
      expect(find.textContaining('is off'), findsNothing);
      expect(result, 1);
    });
  });
}
