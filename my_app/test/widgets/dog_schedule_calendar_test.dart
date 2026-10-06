import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:paws4thoughtdogs/constants/app_colors.dart';
import 'package:paws4thoughtdogs/models/closure_day.dart';
import 'package:paws4thoughtdogs/models/invoice.dart';
import 'package:paws4thoughtdogs/widgets/dog_schedule_calendar.dart';

void main() {
  // Fixed far-future dates so the widget's "no editing past days" guard
  // (which reads the real clock) never interferes with the test.
  final firstDay = DateTime(2030, 6, 1);

  Widget buildCalendar({
    required void Function(DateTime) onBookedDayTap,
    required void Function(DateTime) onFreeDayTap,
    void Function(DateTime)? onBoardingDayTap,
    bool isStaff = false,
    Map<DateTime, InvoiceCoverage>? invoiceCoverage,
    void Function(InvoiceCoverage)? onInvoiceTap,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DogScheduleCalendar(
            firstDay: firstDay,
            lastDay: DateTime(2030, 12, 31),
            bookedDates: {DateTime(2030, 6, 10), DateTime(2030, 6, 17)},
            extraDates: {DateTime(2030, 6, 17)},
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
            onBoardingDayTap: onBoardingDayTap,
            invoiceCoverage: invoiceCoverage,
            onInvoiceTap: onInvoiceTap,
          ),
        ),
      ),
    );
  }

  group('invoice coverage (payment managers)', () {
    const coverage = InvoiceCoverage(
      invoiceId: 12,
      periodLabel: 'June 2030',
      xeroInvoiceNumber: 'INV-0042',
      status: 'SENT',
      statusDisplay: 'Sent',
    );

    testWidgets('without coverage there are no dots and no invoice legend', (tester) async {
      await tester.pumpWidget(buildCalendar(onBookedDayTap: (_) {}, onFreeDayTap: (_) {}, isStaff: true));
      expect(find.byKey(const ValueKey('invoice-dot-2030-6-10')), findsNothing);
      expect(find.text('Invoiced'), findsNothing);
      expect(find.textContaining('long-press'), findsNothing);
    });

    testWidgets('an invoiced day gets a dot, the legend appears and a long-press opens the invoice',
        (tester) async {
      InvoiceCoverage? opened;
      await tester.pumpWidget(buildCalendar(
        onBookedDayTap: (_) {},
        onFreeDayTap: (_) {},
        isStaff: true,
        invoiceCoverage: {DateTime(2030, 6, 10): coverage},
        onInvoiceTap: (c) => opened = c,
      ));

      expect(find.byKey(const ValueKey('invoice-dot-2030-6-10')), findsOneWidget);
      expect(find.byKey(const ValueKey('invoice-dot-2030-6-20')), findsNothing);
      expect(find.text('Invoiced'), findsOneWidget);
      expect(find.textContaining('long-press the day'), findsOneWidget);

      await tester.longPress(find.text('10'));
      await tester.pumpAndSettle();
      expect(find.text('Invoice #12 — June 2030 (INV-0042)'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      await tester.tap(find.text('Open invoice'));
      await tester.pumpAndSettle();
      expect(opened?.invoiceId, 12);

      // A day on no invoice says so.
      await tester.longPress(find.text('20'));
      await tester.pumpAndSettle();
      expect(find.text('Not on any invoice yet.'), findsOneWidget);
    });
  });

  testWidgets('renders legend and month grid', (tester) async {
    await tester.pumpWidget(
      buildCalendar(onBookedDayTap: (_) {}, onFreeDayTap: (_) {}),
    );

    expect(find.text('June 2030'), findsOneWidget);
    expect(find.text('Regular day'), findsOneWidget);
    expect(find.text('Extra day'), findsOneWidget);
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

  testWidgets('an extra day is teal, a regular day green, and both tap as booked',
      (tester) async {
    DateTime? tapped;
    await tester.pumpWidget(
      buildCalendar(onBookedDayTap: (d) => tapped = d, onFreeDayTap: (_) {}),
    );

    Color? fillOf(String day) {
      final container = tester.widget<Container>(find.ancestor(
        of: find.text(day),
        matching: find.byType(Container),
      ).first);
      return (container.decoration as BoxDecoration?)?.color;
    }

    expect(fillOf('17'), AppColors.extraDay);
    expect(fillOf('10'), const Color(0xFF2E7D32));

    await tester.tap(find.text('17'));
    expect(tapped, DateTime(2030, 6, 17));
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

  testWidgets('boarding days fire onBoardingDayTap when provided (staff)',
      (tester) async {
    DateTime? boardingTapped;
    await tester.pumpWidget(buildCalendar(
      isStaff: true,
      onBookedDayTap: (_) {},
      onFreeDayTap: (_) {},
      onBoardingDayTap: (d) => boardingTapped = d,
    ));

    // Approved boarding day.
    await tester.tap(find.text('13'));
    expect(boardingTapped, DateTime(2030, 6, 13));

    // Pending boarding day fires it too.
    await tester.tap(find.text('14'));
    expect(boardingTapped, DateTime(2030, 6, 14));
  });

  testWidgets('boarding days only explain when no handler is provided',
      (tester) async {
    DateTime? bookedTapped;
    DateTime? freeTapped;
    await tester.pumpWidget(buildCalendar(
      onBookedDayTap: (d) => bookedTapped = d,
      onFreeDayTap: (d) => freeTapped = d,
    ));

    await tester.tap(find.text('13'));
    await tester.pump();
    expect(find.textContaining('Boarding day'), findsOneWidget);
    expect(bookedTapped, isNull);
    expect(freeTapped, isNull);
  });

  testWidgets('a one-night stay colours both days and draws one moon',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DogScheduleCalendar(
            firstDay: firstDay,
            lastDay: DateTime(2030, 12, 31),
            bookedDates: const {},
            pendingAddDates: const {},
            pendingRemoveDates: const {},
            boardingDates: {DateTime(2030, 6, 20), DateTime(2030, 6, 21)},
            pendingBoardingDates: const {},
            boardingNights: {DateTime(2030, 6, 20)},
            closures: const {},
            isStaff: false,
            onBookedDayTap: (_) {},
            onFreeDayTap: (_) {},
          ),
        ),
      ),
    ));

    expect(find.byKey(const ValueKey('night-2030-6-20')), findsOneWidget);
    expect(find.byKey(const ValueKey('night-2030-6-21')), findsNothing);
    expect(find.text('Night boarding'), findsOneWidget);
  });

  group("a stay's edge days (full day around an overnight)", () {
    // One night, Thu 20 → Fri 21 June 2030.
    final overnightDays = {DateTime(2030, 6, 20), DateTime(2030, 6, 21)};
    final overnightNight = {DateTime(2030, 6, 20)};

    Widget buildStayCalendar({
      Set<DateTime> bookedDates = const {},
      Set<DateTime> extraDates = const {},
      Set<DateTime> pendingAddDates = const {},
      Set<DateTime> boardingDates = const {},
      Set<DateTime> pendingBoardingDates = const {},
      Set<DateTime> boardingNights = const {},
      Set<DateTime> pendingBoardingNights = const {},
      void Function(DateTime)? onBookedDayTap,
      void Function(DateTime)? onFreeDayTap,
      void Function(DateTime)? onBoardingDayTap,
      bool isStaff = false,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DogScheduleCalendar(
              firstDay: firstDay,
              lastDay: DateTime(2030, 12, 31),
              bookedDates: bookedDates,
              extraDates: extraDates,
              pendingAddDates: pendingAddDates,
              pendingRemoveDates: const {},
              boardingDates: boardingDates,
              pendingBoardingDates: pendingBoardingDates,
              boardingNights: boardingNights,
              pendingBoardingNights: pendingBoardingNights,
              closures: const {},
              isStaff: isStaff,
              onBookedDayTap: onBookedDayTap ?? (_) {},
              onFreeDayTap: onFreeDayTap ?? (_) {},
              onBoardingDayTap: onBoardingDayTap,
            ),
          ),
        ),
      );
    }

    BoxDecoration? decorationOf(WidgetTester tester, String day) {
      final container = tester.widget<Container>(find.ancestor(
        of: find.text(day),
        matching: find.byType(Container),
      ).first);
      return container.decoration as BoxDecoration?;
    }

    testWidgets('owners tap the arrival and going-home days like free days',
        (tester) async {
      DateTime? freeTapped;
      await tester.pumpWidget(buildStayCalendar(
        boardingDates: overnightDays,
        boardingNights: overnightNight,
        onFreeDayTap: (d) => freeTapped = d,
      ));

      // Going-home day: the dog only boards into its morning, so an extra
      // day (full day after the overnight) can be requested on it.
      await tester.tap(find.text('21'));
      expect(freeTapped, DateTime(2030, 6, 21));

      // Arrival day is the mirror image (daycare day, then boards).
      await tester.tap(find.text('20'));
      expect(freeTapped, DateTime(2030, 6, 20));
    });

    testWidgets('a pending stay behaves the same', (tester) async {
      DateTime? freeTapped;
      await tester.pumpWidget(buildStayCalendar(
        pendingBoardingDates: overnightDays,
        pendingBoardingNights: overnightNight,
        onFreeDayTap: (d) => freeTapped = d,
      ));

      await tester.tap(find.text('21'));
      expect(freeTapped, DateTime(2030, 6, 21));
    });

    testWidgets('mid-stay days still explain (and name the stay)',
        (tester) async {
      DateTime? freeTapped;
      await tester.pumpWidget(buildStayCalendar(
        // Two nights, Thu 20 → Sat 22: day 21 boards on both sides.
        boardingDates: {
          DateTime(2030, 6, 20),
          DateTime(2030, 6, 21),
          DateTime(2030, 6, 22),
        },
        boardingNights: {DateTime(2030, 6, 20), DateTime(2030, 6, 21)},
        onFreeDayTap: (d) => freeTapped = d,
      ));

      await tester.tap(find.text('21'));
      await tester.pump();
      expect(find.textContaining('2 nights, Thu 20 – Sat 22 Jun'), findsOneWidget);
      expect(freeTapped, isNull);
    });

    testWidgets('staff taps on an edge day still open the stay',
        (tester) async {
      DateTime? boardingTapped;
      DateTime? freeTapped;
      await tester.pumpWidget(buildStayCalendar(
        isStaff: true,
        boardingDates: overnightDays,
        boardingNights: overnightNight,
        onBoardingDayTap: (d) => boardingTapped = d,
        onFreeDayTap: (d) => freeTapped = d,
      ));

      await tester.tap(find.text('21'));
      expect(boardingTapped, DateTime(2030, 6, 21));
      expect(freeTapped, isNull);
    });

    testWidgets(
        'an approved extra day on the going-home day renders half boarding, '
        'half extra, taps as booked and earns its legend entry',
        (tester) async {
      DateTime? bookedTapped;
      await tester.pumpWidget(buildStayCalendar(
        boardingDates: overnightDays,
        boardingNights: overnightNight,
        bookedDates: {DateTime(2030, 6, 21)},
        extraDates: {DateTime(2030, 6, 21)},
        onBookedDayTap: (d) => bookedTapped = d,
      ));

      // Boarding half on the left — the night the dog wakes up from.
      final gradient = decorationOf(tester, '21')?.gradient as LinearGradient?;
      expect(gradient, isNotNull);
      expect(gradient!.colors.first, Colors.deepPurple);
      expect(gradient.colors.last, AppColors.extraDay);
      expect(find.text('Boarding + extra day'), findsOneWidget);

      await tester.tap(find.text('21'));
      expect(bookedTapped, DateTime(2030, 6, 21));
    });

    testWidgets('an extra day on the arrival day puts the boarding half right',
        (tester) async {
      await tester.pumpWidget(buildStayCalendar(
        boardingDates: overnightDays,
        boardingNights: overnightNight,
        bookedDates: {DateTime(2030, 6, 20)},
        extraDates: {DateTime(2030, 6, 20)},
      ));

      final gradient = decorationOf(tester, '20')?.gradient as LinearGradient?;
      expect(gradient, isNotNull);
      expect(gradient!.colors.first, AppColors.extraDay);
      expect(gradient.colors.last, Colors.deepPurple);
    });

    testWidgets(
        'a pending extra-day request on the going-home day rings the day and '
        'explains on tap', (tester) async {
      DateTime? freeTapped;
      await tester.pumpWidget(buildStayCalendar(
        boardingDates: overnightDays,
        boardingNights: overnightNight,
        // A pending ADD_DAY also counts into booked/extra dates upstream.
        bookedDates: {DateTime(2030, 6, 21)},
        extraDates: {DateTime(2030, 6, 21)},
        pendingAddDates: {DateTime(2030, 6, 21)},
        onFreeDayTap: (d) => freeTapped = d,
      ));

      final decoration = decorationOf(tester, '21');
      expect(decoration?.gradient, isNull);
      expect(decoration?.color, Colors.deepPurple);
      expect((decoration?.border as Border?)?.top.color, AppColors.warning);
      // Not approved yet, so no split-day legend entry either.
      expect(find.text('Boarding + extra day'), findsNothing);

      await tester.tap(find.text('21'));
      await tester.pump();
      expect(find.textContaining('awaiting staff approval'), findsOneWidget);
      expect(freeTapped, isNull);
    });
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
