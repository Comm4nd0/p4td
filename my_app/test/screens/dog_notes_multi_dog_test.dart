import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/models/dog_note.dart';
import 'package:paws4thoughtdogs/screens/dog_notes_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

/// Staff sometimes need to say a group of dogs mustn't all be in together,
/// though any two of them are fine. One entry with several dogs saves one
/// group note: the first picked as related_dog, the rest as extra_dogs.
class _NotesFake extends MockDataService {
  final created = <({int dogId, int? relatedDogId, List<int> extraDogIds, bool isPositive, String text})>[];

  @override
  Future<List<Dog>> getDogs() async => [
        Dog(id: '1', name: 'Rex', ownerId: '9'),
        Dog(id: '2', name: 'Buddy', ownerId: '9'),
        Dog(id: '3', name: 'Luna', ownerId: '9'),
        Dog(id: '4', name: 'Max', ownerId: '9'),
      ];

  @override
  Future<List<DogNote>> getDogNotes({int? dogId, String? noteType}) async => [];

  @override
  Future<DogNote> createDogNote({
    required int dogId,
    int? relatedDogId,
    List<int> extraDogIds = const [],
    required DogNoteType noteType,
    required String text,
    bool isPositive = true,
  }) async {
    created.add((dogId: dogId, relatedDogId: relatedDogId, extraDogIds: extraDogIds, isPositive: isPositive, text: text));
    return DogNote(
      id: created.length,
      dogId: dogId,
      dogName: 'Rex',
      relatedDogId: relatedDogId,
      noteType: noteType,
      text: text,
      isPositive: isPositive,
      createdAt: DateTime(2026, 10, 17),
    );
  }
}

Future<void> _pick(WidgetTester tester, String name) async {
  await tester.tap(find.byType(TextField).first);
  await tester.enterText(find.byType(TextField).first, name);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, name));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('one compatibility entry with several dogs saves one group note',
      (tester) async {
    final fake = _NotesFake();
    if (getIt.isRegistered<DataService>()) getIt.unregister<DataService>();
    getIt.registerSingleton<DataService>(fake);
    addTearDown(() => getIt.unregister<DataService>());

    await tester.pumpWidget(const MaterialApp(
      home: DogNotesScreen(dogId: 1, dogName: 'Rex'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Negative'));
    await tester.pumpAndSettle();

    await _pick(tester, 'Buddy');
    await _pick(tester, 'Luna');
    await _pick(tester, 'Max');

    // All three stay picked as chips, and the search field is clear again.
    expect(find.widgetWithText(InputChip, 'Buddy'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Luna'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Max'), findsOneWidget);
    expect(
        find.text('Fine in any pair — flagged only when Rex and all 3 of these are in together.'),
        findsOneWidget);

    // Removing one takes it off the entry.
    await tester.tap(find.descendant(
      of: find.widgetWithText(InputChip, 'Luna'),
      matching: find.byTooltip('Delete'),
    ));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Luna'), findsNothing);
    await _pick(tester, 'Luna');

    await tester.enterText(find.byType(TextField).last, 'Do not mix');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(fake.created, hasLength(1));
    final note = fake.created.single;
    expect(note.dogId, 1);
    // Luna was removed and re-added, so she is now last.
    expect([note.relatedDogId, ...note.extraDogIds], [2, 4, 3]);
    expect(note.isPositive, isFalse);
    expect(note.text, 'Do not mix');
  });

  test('a group note lists every other dog on each profile it names', () {
    final note = DogNote.fromJson({
      'id': 1,
      'dog': 1,
      'dog_name': 'Rex',
      'related_dog': 2,
      'related_dog_name': 'Buddy',
      'extra_dogs': [3],
      'extra_dog_names': ['Luna'],
      'note_type': 'COMPATIBILITY',
      'text': 'Not all three',
      'is_positive': false,
      'created_at': '2026-10-17T09:00:00Z',
    });
    expect(note.isGroup, isTrue);
    expect(note.otherDogNames(1), ['Buddy', 'Luna']);
    expect(note.otherDogNames(3), ['Rex', 'Buddy']);
  });
}
