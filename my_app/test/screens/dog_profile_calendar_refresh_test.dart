import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/date_change_request.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/screens/dog_home_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/widgets/dog_schedule_calendar.dart';

/// Behaves like the API: approving a cancellation deletes the day's board row
/// and records the request, so the server's dog changes under the screen.
class _Server extends MockDataService {
  _Server(this.dog);

  Dog dog;
  final List<DateChangeRequest> requests = [];

  @override
  Future<Dog> getDogById(String dogId) async => dog;

  @override
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId}) async =>
      List.of(requests);

  @override
  Future<void> submitAdditionalDayRequest({
    required String dogId,
    required DateTime requestedDate,
  }) async {
    requests.add(DateChangeRequest(
      id: '${requests.length + 1}',
      dogId: dogId,
      dogName: dog.name,
      ownerName: 'Owner',
      requestType: RequestType.addDay,
      newDate: requestedDate,
      status: RequestStatus.approved,
      isCharged: false,
      createdAt: DateTime.now(),
    ));
  }

  @override
  Future<void> submitDateChangeRequest({
    required String dogId,
    required DateTime originalDate,
    DateTime? newDate,
  }) async {
    requests.add(DateChangeRequest(
      id: '${requests.length + 1}',
      dogId: dogId,
      dogName: dog.name,
      ownerName: 'Owner',
      requestType: newDate == null ? RequestType.cancel : RequestType.change,
      originalDate: originalDate,
      newDate: newDate,
      status: RequestStatus.approved,
      isCharged: false,
      createdAt: DateTime.now(),
    ));
    dog = dog.copyWith(assignedDates: const []);
  }
}

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final cross = find.byKey(ValueKey('cancelled-${today.year}-${today.month}-${today.day}'));
  late _Server server;
  late Dog listDog; // what the home list still holds

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: DogHomeScreen(key: UniqueKey(), dog: listDog, isStaff: true),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    final base = (await MockDataService().getDogs()).first;
    listDog = base.copyWith(daysInDaycare: const [], assignedDates: [today]);
    server = _Server(listDog);
    await getIt.reset();
    getIt.registerSingleton<DataService>(server);
  });

  tearDown(() => getIt.reset());

  testWidgets('cancelling a day from the calendar shows on it straight away',
      (tester) async {
    await open(tester);
    expect(cross, findsNothing);

    await tester.tap(find.descendant(
      of: find.byType(DogScheduleCalendar),
      matching: find.text('${today.day}'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel Date'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm Cancellation'));
    await tester.pumpAndSettle();

    expect(cross, findsOneWidget);
  });

  testWidgets('adding a day from the calendar shows on it straight away',
      (tester) async {
    listDog = listDog.copyWith(assignedDates: const []);
    server.dog = listDog;
    await open(tester);

    await tester.tap(find.descendant(
      of: find.byType(DogScheduleCalendar),
      matching: find.text('${today.day}'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit 1 Request'));
    await tester.pumpAndSettle();

    final calendar = tester.widget<DogScheduleCalendar>(find.byType(DogScheduleCalendar));
    expect(calendar.bookedDates, contains(today));
    expect(calendar.extraDates, contains(today));
  });

  testWidgets('reopening the profile from a stale home list keeps the change',
      (tester) async {
    await server.submitDateChangeRequest(dogId: listDog.id, originalDate: today);

    await open(tester);

    expect(cross, findsOneWidget);
  });
}
