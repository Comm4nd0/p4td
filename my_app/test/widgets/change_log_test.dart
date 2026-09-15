import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
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
  String category = 'DOG',
  String categoryDisplay = 'Dogs',
  List<DogFieldChange> changes = const [],
}) =>
    DogChangeLog(
      id: id,
      category: category,
      categoryDisplay: categoryDisplay,
      dogId: category == 'DOG' ? '7' : null,
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

typedef _Call = ({String? dogId, int? limit, String? actorId, String? action, String? category, DateTime? from, DateTime? to});

class _FakeDataService extends MockDataService {
  final List<DogChangeLog> entries;
  final List<_Call> calls = [];
  _FakeDataService(this.entries);

  @override
  Future<List<DogChangeLog>> getDogChangeLogs({
    String? dogId,
    int? limit,
    String? actorId,
    String? action,
    String? category,
    DateTime? from,
    DateTime? to,
  }) async {
    calls.add((dogId: dogId, limit: limit, actorId: actorId, action: action, category: category, from: from, to: to));
    return entries;
  }

  @override
  Future<List<Dog>> getDogs() async => [Dog(id: '7', name: 'Buddy', ownerId: '2')];

  @override
  Future<List<DogChangeActor>> getDogChangeLogActors() async => const [
        DogChangeActor(id: '5', name: 'Sam Jones'),
        DogChangeActor(id: null, name: 'System'),
      ];
}

void _register(DataService fake) {
  if (getIt.isRegistered<DataService>()) getIt.unregister<DataService>();
  getIt.registerSingleton<DataService>(fake);
  addTearDown(() => getIt.unregister<DataService>());
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
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

      expect(find.text('Recent Activity'), findsOneWidget);
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

    testWidgets('a non-dog entry names its subject and area', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChangeLogSection(entries: [
            _entry(
              id: 1,
              dog: 'Olivia Owen',
              category: 'COMMS',
              categoryDisplay: 'Client communications',
              action: 'MESSAGE',
              summary: "Replied to Olivia Owen: 'Lead lost'",
            ),
          ]),
        ),
      ));

      expect(find.text("Olivia Owen — Replied to Olivia Owen: 'Lead lost'"), findsOneWidget);
      expect(find.text('Sam Jones · Client communications · 15/09/26 10:30'), findsOneWidget);
    });

    testWidgets('empty and failed states', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ChangeLogSection(entries: [])),
      ));
      expect(find.text('No activity recorded yet'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ChangeLogSection(entries: [], failed: true)),
      ));
      expect(find.text("Couldn't load recent activity — pull down to retry"), findsOneWidget);
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
      await _settle(tester);

      expect(fake.calls.single.dogId, '7');
      expect(fake.calls.single.limit, isNull);
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
      await _settle(tester);

      expect(find.text('Activity Log'), findsOneWidget);
      expect(find.text('Luna — Updated food instructions'), findsOneWidget);
    });

    testWidgets('an empty log says so', (tester) async {
      _register(_FakeDataService(const []));

      await tester.pumpWidget(const MaterialApp(home: DogChangeLogScreen(dogName: 'Buddy')));
      await _settle(tester);

      expect(find.text('No changes recorded for Buddy yet'), findsOneWidget);
    });

    testWidgets('filters are sent to the API, shown as chips, and dropped one at a time',
        (tester) async {
      final fake = _FakeDataService(const []);
      _register(fake);

      await tester.pumpWidget(MaterialApp(
        home: DogChangeLogScreen(
          initialFilter: DogChangeLogFilter(
            dogId: '7',
            dogName: 'Buddy',
            actorId: '5',
            actorName: 'Sam Jones',
            action: 'VACCINATION',
            from: DateTime(2026, 9, 1),
            to: DateTime(2026, 9, 15),
          ),
        ),
      ));
      await _settle(tester);

      final first = fake.calls.single;
      expect(first.dogId, '7');
      expect(first.actorId, '5');
      expect(first.action, 'VACCINATION');
      expect(first.from, DateTime(2026, 9, 1));
      expect(first.to, DateTime(2026, 9, 15));

      expect(find.text('Buddy'), findsOneWidget);
      expect(find.text('Sam Jones'), findsOneWidget);
      expect(find.text('Vaccination'), findsOneWidget);
      expect(find.text('01/09/26 – 15/09/26'), findsOneWidget);
      expect(find.text('Nothing matches these filters'), findsOneWidget);

      // × on the type chip re-queries without it; the rest stay. (The chip's
      // Picon avatar is two Icons; the delete icon is the last one.)
      await tester.tap(find
          .descendant(
            of: find.widgetWithText(InputChip, 'Vaccination'),
            matching: find.byType(Icon),
          )
          .last);
      await _settle(tester);

      expect(fake.calls.length, 2);
      expect(fake.calls.last.action, isNull);
      expect(fake.calls.last.actorId, '5');
      expect(find.text('Vaccination'), findsNothing);
      expect(find.text('Sam Jones'), findsOneWidget);

      // Clear drops everything and asks for the whole log.
      await tester.tap(find.text('Clear'));
      await _settle(tester);
      expect(fake.calls.last, (dogId: null, limit: null, actorId: null, action: null, category: null, from: null, to: null));
      expect(find.byType(InputChip), findsNothing);
    });

    testWidgets('the Filters sheet applies a type of change', (tester) async {
      final fake = _FakeDataService(const []);
      _register(fake);

      await tester.pumpWidget(const MaterialApp(home: DogChangeLogScreen()));
      await _settle(tester);

      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      expect(find.text('Filter activity'), findsOneWidget);
      // The master log offers a dog picker; a single dog's log would not.
      expect(find.byKey(const Key('filter-dog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('filter-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gallery').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(fake.calls.last.action, 'PHOTO');
      expect(find.widgetWithText(InputChip, 'Gallery'), findsOneWidget);
    });

    testWidgets('the Filters sheet narrows the master log to one area', (tester) async {
      final fake = _FakeDataService(const []);
      _register(fake);

      await tester.pumpWidget(const MaterialApp(home: DogChangeLogScreen()));
      await _settle(tester);

      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fleet').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(fake.calls.last.category, 'FLEET');
      expect(find.widgetWithText(InputChip, 'Fleet'), findsOneWidget);
    });

    testWidgets("one dog's log has no area picker and never sends a category", (tester) async {
      final fake = _FakeDataService(const []);
      _register(fake);

      await tester.pumpWidget(const MaterialApp(home: DogChangeLogScreen(dogId: '7', dogName: 'Buddy')));
      await _settle(tester);
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-category')), findsNothing);
      expect(fake.calls.single.category, isNull);
    });
  });
}
