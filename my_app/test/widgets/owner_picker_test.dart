import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/owner_profile.dart';
import 'package:paws4thoughtdogs/widgets/owner_picker.dart';

/// Staff know a client as "Sue" or by the email on the booking form, so the
/// picker has to find people by any part of either.
final _owners = [
  OwnerProfile(userId: 1, username: 'sue@example.com', firstName: 'Sue', lastName: 'Penney', email: 'sue@example.com'),
  OwnerProfile(userId: 2, username: 'glenn@example.com', firstName: 'Glenn', lastName: 'Hart', email: 'glenn@example.com'),
  OwnerProfile(userId: 3, username: 'legacy_user', email: 'old@example.org'),
];

/// Opens the picker and hands back where its result will land once the
/// dialog closes (the dialog's future can't be awaited mid-test).
class _Opened {
  OwnerPick? result;
  bool closed = false;
}

Future<_Opened> _open(WidgetTester tester, {bool allowNone = false, int? selectedId}) async {
  final opened = _Opened();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () {
          showOwnerPicker(context, owners: _owners, allowNone: allowNone, selectedId: selectedId)
              .then((pick) {
            opened.result = pick;
            opened.closed = true;
          });
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  test('matches on any word of the name, username or email', () {
    final sue = _owners[0];
    expect(sue.matches('sue'), isTrue);
    expect(sue.matches('PENNEY'), isTrue);
    expect(sue.matches('sue pen'), isTrue);
    expect(sue.matches('sue@'), isTrue);
    expect(sue.matches('glenn'), isFalse);
    expect(sue.matches(''), isTrue);
    expect(_owners[2].displayName, 'legacy_user');
    expect(_owners[2].matches('old@example'), isTrue);
  });

  testWidgets('typing narrows the list by name or email', (tester) async {
    await _open(tester);
    expect(find.text('Sue Penney'), findsOneWidget);
    expect(find.text('Glenn Hart'), findsOneWidget);
    expect(find.text('legacy_user'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'pen');
    await tester.pumpAndSettle();
    expect(find.text('Sue Penney'), findsOneWidget);
    expect(find.text('Glenn Hart'), findsNothing);

    await tester.enterText(find.byType(TextField), 'old@example');
    await tester.pumpAndSettle();
    expect(find.text('legacy_user'), findsOneWidget);
    expect(find.text('Sue Penney'), findsNothing);

    await tester.enterText(find.byType(TextField), 'nobody');
    await tester.pumpAndSettle();
    expect(find.text('No one matches that.'), findsOneWidget);
  });

  testWidgets('tapping a person returns them; cancel returns nothing', (tester) async {
    final picked = await _open(tester);
    await tester.tap(find.text('Glenn Hart'));
    await tester.pumpAndSettle();
    expect(picked.closed, isTrue);
    expect(picked.result?.owner?.userId, 2);

    final cancelled = await _open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cancelled.closed, isTrue);
    expect(cancelled.result, isNull);
  });

  testWidgets('"No owner" is offered only when allowed, and only before typing', (tester) async {
    final picked = await _open(tester, allowNone: true, selectedId: 1);
    expect(find.text('No owner'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'sue');
    await tester.pumpAndSettle();
    expect(find.text('No owner'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('No owner'));
    await tester.pumpAndSettle();
    expect(picked.closed, isTrue);
    expect(picked.result, isNotNull);
    expect(picked.result!.owner, isNull);
  });

  testWidgets('the field validates like any form field', (tester) async {
    final formKey = GlobalKey<FormState>();
    int? value;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Form(
            key: formKey,
            child: OwnerPickerField(
              owners: _owners,
              value: value,
              onChanged: (v) => setState(() => value = v),
              validator: (v) => v == null ? 'Required for staff' : null,
            ),
          ),
        ),
      ),
    ));
    expect(formKey.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('Required for staff'), findsOneWidget);

    await tester.tap(find.text('Tap to search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'glenn');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Glenn Hart'));
    await tester.pumpAndSettle();
    expect(value, 2);
    expect(find.textContaining('Glenn Hart'), findsOneWidget);
    expect(formKey.currentState!.validate(), isTrue);
  });
}
