import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/date_change_request.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/screens/dog_home_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

class _Server extends MockDataService {
  _Server(this.dog);

  Dog dog;
  bool failRequests = false;
  bool failDays = false;

  @override
  Future<Dog> getDogById(String dogId) async => dog;

  @override
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId}) async {
    if (failRequests) throw Exception('No signal');
    return [];
  }

  @override
  Future<void> submitAdditionalDayRequest({
    required String dogId,
    required DateTime requestedDate,
  }) async {
    if (failDays) throw Exception('That day is full');
  }
}

void main() {
  late _Server server;
  late Dog listDog; // the copy the home list loaded this morning

  Future<void> open(WidgetTester tester, {bool isStaff = true}) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: DogHomeScreen(key: UniqueKey(), dog: listDog, isStaff: isStaff),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    listDog = (await MockDataService().getDogs()).first.copyWith(name: 'Old Name');
    server = _Server(listDog);
    await getIt.reset();
    getIt.registerSingleton<DataService>(server);
  });

  tearDown(() => getIt.reset());

  testWidgets('the profile shows the dog as the server has it, not the list copy',
      (tester) async {
    // Someone else has changed the dog since the list was loaded. Keeping
    // the stale copy meant Edit opened on it and saved it all back.
    server.dog = listDog.copyWith(name: 'New Name');
    await open(tester);

    expect(find.text('New Name'), findsWidgets);
    expect(find.text('Old Name'), findsNothing);
  });

  testWidgets('a failed schedule load says so above the calendar and can be retried',
      (tester) async {
    server.failRequests = true;
    await open(tester, isStaff: false);

    const strip = ValueKey('schedule-load-failed');
    expect(find.byKey(strip), findsOneWidget);
    expect(find.textContaining('may be missing'), findsOneWidget);

    server.failRequests = false;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.byKey(strip), findsNothing);
  });

  testWidgets('nothing is shown above the calendar when the loads succeed', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('schedule-load-failed')), findsNothing);
  });
}
