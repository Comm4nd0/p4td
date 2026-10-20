import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/boarding_request.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/widgets/boarding_request_card.dart';
import 'package:paws4thoughtdogs/widgets/dog_quick_info_sheet.dart';

DateTime _day(int offset) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + offset);
}

String _ymd(DateTime d) => d.toIso8601String().split('T').first;

BoardingRequest _booking({
  String status = 'APPROVED',
  int start = 5,
  int end = 8,
  int? askedStart,
  int? askedEnd,
}) =>
    BoardingRequest.fromJson({
      'id': 1,
      'owner': 2,
      'owner_name': 'Jo Bloggs',
      'dogs': [3],
      'dog_names': ['Bella'],
      'start_date': _ymd(_day(start)),
      'end_date': _ymd(_day(end)),
      'status': status,
      'created_at': DateTime.now().toIso8601String(),
      'has_pending_change': askedStart != null,
      'requested_start_date': askedStart != null ? _ymd(_day(askedStart)) : null,
      'requested_end_date': askedEnd != null ? _ymd(_day(askedEnd)) : null,
      'change_note': askedStart != null ? 'Flight moved' : '',
      'change_requested_by_name': askedStart != null ? 'Jo Bloggs' : null,
    });

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  test('owners may ask to change an approved stay until its last day', () {
    expect(_booking().canRequestChange, isTrue);
    expect(_booking(start: -3, end: 0).canRequestChange, isTrue);
    expect(_booking(start: -5, end: -1).canRequestChange, isFalse);
    expect(_booking(status: 'PENDING').canRequestChange, isFalse);
    expect(_booking(start: -1, end: 3).hasStarted, isTrue);
    expect(_booking(start: 1, end: 3).hasStarted, isFalse);
  });

  testWidgets('owner sees Change dates on an approved upcoming stay', (tester) async {
    await tester.pumpWidget(_wrap(BoardingRequestCard(
      request: _booking(),
      onRequestChange: () {},
      onWithdrawChange: () {},
    )));
    expect(find.text('Change dates'), findsOneWidget);
    expect(find.text('Withdraw change'), findsNothing);
  });

  testWidgets('owner sees no change button once the stay has finished', (tester) async {
    await tester.pumpWidget(_wrap(BoardingRequestCard(
      request: _booking(start: -6, end: -2),
      onRequestChange: () {},
    )));
    expect(find.text('Change dates'), findsNothing);
  });

  testWidgets('owner with a pending change can edit or withdraw it', (tester) async {
    await tester.pumpWidget(_wrap(BoardingRequestCard(
      request: _booking(askedStart: 5, askedEnd: 10),
      onRequestChange: () {},
      onWithdrawChange: () {},
    )));
    expect(find.text('Date change requested — awaiting approval'), findsOneWidget);
    expect(find.text('Edit change'), findsOneWidget);
    expect(find.text('Withdraw change'), findsOneWidget);
    expect(find.text('Approve change'), findsNothing);
  });

  testWidgets('manager reviews the requested dates', (tester) async {
    var approved = false;
    await tester.pumpWidget(_wrap(BoardingRequestCard(
      request: _booking(askedStart: 5, askedEnd: 10),
      showOwner: true,
      canManage: true,
      onApproveChange: () => approved = true,
      onDenyChange: () {},
      onEdit: () {},
    )));
    expect(find.text('Jo Bloggs asked to change the dates'), findsOneWidget);
    expect(find.text('"Flight moved"'), findsOneWidget);
    await tester.tap(find.text('Approve change'));
    expect(approved, isTrue);
    expect(find.text('Decline'), findsOneWidget);
    // Managers still have the direct edit.
    expect(find.byTooltip('Edit dates & instructions'), findsOneWidget);
  });

  testWidgets('dashboard boarding sheet shows Edit booking only when given', (tester) async {
    final dog = Dog(id: '3', name: 'Bella', ownerId: '2');
    var edited = false;
    await tester.pumpWidget(_wrap(DogQuickInfoSheet(dog: dog, onEditBooking: () => edited = true)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit boarding booking'));
    expect(edited, isTrue);

    await tester.pumpWidget(_wrap(DogQuickInfoSheet(dog: dog)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit boarding booking'), findsNothing);
  });
}
