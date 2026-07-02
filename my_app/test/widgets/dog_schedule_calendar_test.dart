import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/closure_day.dart';
import 'package:paws4thoughtdogs/widgets/dog_schedule_calendar.dart';

void main() {
  // Fixed far-future dates so the widget's "no editing past days" guard
  // (which reads the real clock) never interferes with the test.
  final firstDay = DateTime(2030, 6, 1);

  Widget buildCalendar({
    required void Function(DateTime) onBookedDayTap,
    required void Function(DateTime) onFreeDayTap,
    bool isStaff = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DogScheduleCalendar(
            firstDay: firstDay,
            lastDay: DateTime(2030, 12, 31),
            bookedDates: {DateTime(2030, 6, 10)},
            pendingAddDates: {DateTime(2030, 6, 11)},
            pendingRemoveDates: {DateTime(2030, 6, 12)},
            boardingDates: {DateTime(2030, 6, 13)},
            pendingBoardingDates: {DateTime(2030, 6, 14)},
            closures: {
              DateTime(2030, 6, 15): ClosureDay(
                id: 1,
                date: DateTime(2030, 6, 15),
                closureType: ClosureType.closed,
                reason: 'Holiday',
              ),
            },
            isStaff: isStaff,
            onBookedDayTap: onBookedDayTap,
            onFreeDayTap: onFreeDayTap,
          ),
        ),
      ),
    );
  }

  testWidgets('renders legend and month grid', (tester) async {
    await tester.pumpWidget(
      buildCalendar(onBookedDayTap: (_) {}, onFreeDayTap: (_) {}),
    );

    expect(find.text('June 2030'), findsOneWidget);
    expect(find.text('Booked'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Boarding'), findsOneWidget);
    expect(find.text('Closed'), findsOneWidget);
  });

  testWidgets('tapping a booked day fires onBookedDayTap', (tester) async {
    DateTime? tapped;
    await tester.pumpWidget(
      buildCalendar(onBookedDayTap: (d) => tapped = d, onFreeDayTap: (_) {}),
    );

    await tester.tap(find.text('10'));
    expect(tapped, DateTime(2030, 6, 10));
  });

  testWidgets('tapping a free day fires onFreeDayTap', (tester) async {
    DateTime? tapped;
    await tester.pumpWidget(
      buildCalendar(onBookedDayTap: (_) {}, onFreeDayTap: (d) => tapped = d),
    );

    await tester.tap(find.text('20'));
    expect(tapped, DateTime(2030, 6, 20));
  });

  testWidgets('closed and pending days explain instead of editing',
      (tester) async {
    DateTime? bookedTapped;
    DateTime? freeTapped;
    await tester.pumpWidget(buildCalendar(
      onBookedDayTap: (d) => bookedTapped = d,
      onFreeDayTap: (d) => freeTapped = d,
    ));

    // Closed day: snackbar with the reason, no add-day callback.
    await tester.tap(find.text('15'));
    await tester.pump();
    expect(find.textContaining('closed'), findsOneWidget);
    expect(freeTapped, isNull);

    // Pending add day: informational snackbar (replacing the previous one),
    // no callbacks.
    await tester.tap(find.text('11'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('awaiting staff approval'), findsOneWidget);
    expect(bookedTapped, isNull);
    expect(freeTapped, isNull);
  });
}
