import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/dog_change_log.dart';
import 'package:paws4thoughtdogs/screens/dashboard/change_log_section.dart';
import 'package:paws4thoughtdogs/screens/dog_change_log_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

DogChangeLog _entry({
  required int id,
  String dog = 'Buddy',
  String action = 'UPDATED',
  String summary = 'Updated food instructions',
  String actor = 'Sam Jones',
  String source = 'APP',
  String sourceDisplay = 'App',
  List<DogFieldChange> changes = const [],
}) =>
    DogChangeLog(
      id: id,
      dogId: '7',
      dogName: dog,
      actorName: actor,
      action: action,
      actionDisplay: 'Updated',
      source: source,
      sourceDisplay: sourceDisplay,
      summary: summary,
      changes: changes,
      createdAt: DateTime(2026, 9, 15, 10, 30),
    );

class _FakeDataService extends MockDataService {
  final List<DogChangeLog> entries;
  final List<({String? dogId, int? limit})> calls = [];
  _FakeDataService(this.entries);

  @override
  Future<List<DogChangeLog>> getDogChangeLogs({String? dogId, int? limit}) async {
    calls.add((dogId: dogId, limit: limit));
    return entries;
  }
}

void _register(DataService fake) {
  if (getIt.isRegistered<DataService>()) getIt.unregister<DataService>();
  getIt.registerSingleton<DataService>(fake);
  addTearDown(() => getIt.unregister<DataService>());
}

void main() {
  group('ChangeLogSection', () {
    testWidgets('shows at most five entries, naming dog, actor and time',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChangeLogSection(
            entries: [for (var i = 1; i <= 7; i++) _entry(id: i, summary: 'Change $i')],
            onViewAll: () {},
          ),
        ),
      ));

      expect(find.text('Recent Changes'), findsOneWidget);
      expect(find.text('View all'), findsOneWidget);
      expect(find.text('Buddy — Change 1'), findsOneWidget);
      expect(find.text('Buddy — Change 5'), findsOneWidget);
      expect(find.text('Buddy — Change 6'), findsNothing);
      expect(find.text('Sam Jones · 15/09/26 10:30'), findsNWidgets(5));
    });

    testWidgets('an approved owner request says so beside the approver',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChangeLogSection(entries: [
            _entry(
              id: 1,
              source: 'OWNER_REQUEST',
              sourceDisplay: 'Approved owner request',
              summary: "Approved Alex Smith's request: address",
            ),
          ]),
        ),
      ));

      expect(find.text('Sam Jones · approved owner request · 15/09/26 10:30'), findsOneWidget);
    });

    testWidgets('empty and failed states', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ChangeLogSection(entries: [])),
      ));
      expect(find.text('No changes recorded yet'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ChangeLogSection(entries: [], failed: true)),
      ));
      expect(find.text("Couldn't load recent changes — pull down to retry"), findsOneWidget);
    });
  });

  group('DogChangeLogScreen', () {
    testWidgets("one dog's log asks for that dog and expands the diffs",
        (tester) async {
      final fake = _FakeDataService([
        _entry(id: 1, changes: const [
          DogFieldChange(field: 'name', label: 'Name', oldValue: 'Buddy', newValue: 'Buddy Jr'),
          DogFieldChange(field: 'address', label: 'Address', oldValue: '', newValue: '1 High St'),
        ]),
        _entry(id: 2, action: 'CREATED', summary: 'Added Buddy for Alex Smith'),
      ]);
      _register(fake);

      await tester.pumpWidget(const MaterialApp(
        home: DogChangeLogScreen(dogId: '7', dogName: 'Buddy'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fake.calls, [(dogId: '7', limit: null)]);
      expect(find.text('Buddy — Change Log'), findsOneWidget);
      // A single dog's log doesn't repeat the dog's name on every row.
      expect(find.text('Updated food instructions'), findsOneWidget);
      expect(find.text('Added Buddy for Alex Smith'), findsOneWidget);
      // Diffs are open by default: label, old (or a dash) and new.
      expect(find.textContaining('Name: ', findRichText: true), findsOneWidget);
      expect(find.textContaining('Buddy Jr', findRichText: true), findsOneWidget);
      expect(find.textContaining('1 High St', findRichText: true), findsOneWidget);
    });

    testWidgets('the master log names the dog on each row', (tester) async {
      _register(_FakeDataService([_entry(id: 1, dog: 'Luna')]));

      await tester.pumpWidget(const MaterialApp(home: DogChangeLogScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Change Log'), findsOneWidget);
      expect(find.text('Luna — Updated food instructions'), findsOneWidget);
    });

    testWidgets('an empty log says so', (tester) async {
      _register(_FakeDataService(const []));

      await tester.pumpWidget(const MaterialApp(home: DogChangeLogScreen(dogName: 'Buddy')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('No changes recorded for Buddy yet'), findsOneWidget);
    });
  });
}
