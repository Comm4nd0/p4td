import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
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

  group('past editing (payment managers)', () {
    // These use the real clock (the widget's past guard does too). Day 15 of
    // last month is always in the past and always one page back.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastMonth15 = DateTime(now.year, now.month - 1, 15);

    Widget buildLiveCalendar({
      required DateTime firstDay,
      required bool allowPastEdits,
      required void Function(DateTime) onBookedDayTap,
      required void Function(DateTime) onFreeDayTap,
      Set<DateTime> bookedDates = const {},
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DogScheduleCalendar(
              firstDay: firstDay,
              lastDay: DateTime(now.year, now.month + 3, now.day),
              bookedDates: bookedDates,
              pendingAddDates: const {},
              pendingRemoveDates: const {},
              boardingDates: const {},
              pendingBoardingDates: const {},
              closures: const {},
              isStaff: true,
              allowPastEdits: allowPastEdits,
              onBookedDayTap: onBookedDayTap,
              onFreeDayTap: onFreeDayTap,
            ),
          ),
        ),
      );
    }

    testWidgets('with allowPastEdits the calendar pages back and past days tap',
        (tester) async {
      DateTime? freeTapped;
      DateTime? bookedTapped;
      await tester.pumpWidget(buildLiveCalendar(
        firstDay: DateTime(now.year - 1, now.month, now.day),
        allowPastEdits: true,
        bookedDates: {lastMonth15},
        onBookedDayTap: (d) => bookedTapped = d,
        onFreeDayTap: (d) => freeTapped = d,
      ));

      // Opens on the current month (not a year back)...
      final monthTitle = DateFormat.yMMMM().format(today);
      expect(find.text(monthTitle), findsOneWidget);

      // ...and the header chevron pages into the past.
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text(DateFormat.yMMMM().format(lastMonth15)), findsOneWidget);

      // A past booked day is editable.
      await tester.tap(find.text('15'));
      expect(bookedTapped, lastMonth15);
      expect(freeTapped, isNull);
    });

    testWidgets('without allowPastEdits past taps stay ignored',
        (tester) async {
      DateTime? tapped;
      await tester.pumpWidget(buildLiveCalendar(
        firstDay: DateTime(now.year - 1, now.month, now.day),
        allowPastEdits: false,
        onBookedDayTap: (d) => tapped = d,
        onFreeDayTap: (d) => tapped = d,
      ));

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15'));
      expect(tapped, isNull);
    });

    testWidgets('firstDay extending back after build (async permission load) works',
        (tester) async {
      // The app builds the calendar with firstDay = today, then flips to a
      // year back once the profile/attendance load finishes. The already-built
      // calendar must pick that up.
      DateTime? freeTapped;
      late StateSetter rebuild;
      var canEditPast = false;

      await tester.pumpWidget(StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return buildLiveCalendar(
            firstDay: canEditPast
                ? DateTime(now.year - 1, now.month, now.day)
                : today,
            allowPastEdits: canEditPast,
            onBookedDayTap: (_) {},
            onFreeDayTap: (d) => freeTapped = d,
          );
        },
      ));

      // Before the permission loads there is nowhere to page back to.
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text(DateFormat.yMMMM().format(today)), findsOneWidget);

      // Permission arrives → range extends → paging back now works.
      rebuild(() => canEditPast = true);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text(DateFormat.yMMMM().format(lastMonth15)), findsOneWidget);

      await tester.tap(find.text('15'));
      expect(freeTapped, lastMonth15);
    });
  });
}
