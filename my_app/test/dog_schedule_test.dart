import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/date_change_request.dart';
import 'package:paws4thoughtdogs/utils/dog_schedule.dart';

DateChangeRequest _req({
  required RequestType type,
  required RequestStatus status,
  DateTime? originalDate,
  DateTime? newDate,
}) {
  return DateChangeRequest(
    id: '1',
    dogId: '1',
    dogName: 'Rex',
    ownerName: 'Owner',
    requestType: type,
    originalDate: originalDate,
    newDate: newDate,
    status: status,
    isCharged: false,
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  // A fixed "now" so the tests are deterministic. Wednesday 2026-06-17.
  final now = DateTime(2026, 6, 17);

  group('calendarLastDay', () {
    test('owners are capped three months ahead', () {
      expect(
        calendarLastDay(now, isStaff: false),
        DateTime(2026, 9, 17),
      );
    });

    test('staff can edit five years ahead', () {
      expect(
        calendarLastDay(now, isStaff: true),
        DateTime(2031, 6, 17),
      );
    });
  });

  group('isDateConfirmed', () {
    test('a date within one month is confirmed', () {
      expect(isDateConfirmed(DateTime(2026, 7, 10), now: now), isTrue);
    });

    test('a date exactly one month away is not confirmed', () {
      // oneMonthLater is 2026-07-17; isBefore is strict.
      expect(isDateConfirmed(DateTime(2026, 7, 17), now: now), isFalse);
    });

    test('a date beyond one month is not confirmed', () {
      expect(isDateConfirmed(DateTime(2026, 8, 1), now: now), isFalse);
    });
  });

  group('upcomingDaycareDates', () {
    test('returns recurring weekdays within the three-month window', () {
      // Monday = 1. Expect every Monday from today (Wed 17 Jun) to 17 Sep.
      final dates = upcomingDaycareDates(
        now: now,
        daycareWeekdays: {1},
        requests: const [],
      );

      expect(dates, isNotEmpty);
      // All results are Mondays.
      expect(dates.every((d) => d.weekday == DateTime.monday), isTrue);
      // First Monday on/after Wed 17 Jun 2026 is Mon 22 Jun.
      expect(dates.first, DateTime(2026, 6, 22));
      // Sorted ascending and normalised to midnight.
      final sorted = [...dates]..sort();
      expect(dates, sorted);
      expect(dates.every((d) => d.hour == 0 && d.minute == 0), isTrue);
    });

    test('an active cancellation removes the original date', () {
      final withRequest = upcomingDaycareDates(
        now: now,
        daycareWeekdays: {1},
        requests: [
          _req(
            type: RequestType.cancel,
            status: RequestStatus.approved,
            originalDate: DateTime(2026, 6, 22),
          ),
        ],
      );
      expect(withRequest.contains(DateTime(2026, 6, 22)), isFalse);
    });

    test('an active additional-day adds a non-recurring date', () {
      // Friday 19 Jun is not a recurring Monday, but an add-day request
      // should surface it.
      final dates = upcomingDaycareDates(
        now: now,
        daycareWeekdays: {1},
        requests: [
          _req(
            type: RequestType.addDay,
            status: RequestStatus.pending,
            newDate: DateTime(2026, 6, 19),
          ),
        ],
      );
      expect(dates.contains(DateTime(2026, 6, 19)), isTrue);
    });

    test('a denied request is ignored', () {
      final dates = upcomingDaycareDates(
        now: now,
        daycareWeekdays: {1},
        requests: [
          _req(
            type: RequestType.cancel,
            status: RequestStatus.denied,
            originalDate: DateTime(2026, 6, 22),
          ),
        ],
      );
      // The Monday should still be present because the cancellation is denied.
      expect(dates.contains(DateTime(2026, 6, 22)), isTrue);
    });

    test('a change moves the original date to the new date', () {
      final dates = upcomingDaycareDates(
        now: now,
        daycareWeekdays: {1},
        requests: [
          _req(
            type: RequestType.change,
            status: RequestStatus.approved,
            originalDate: DateTime(2026, 6, 22),
            newDate: DateTime(2026, 6, 24),
          ),
        ],
      );
      expect(dates.contains(DateTime(2026, 6, 22)), isFalse);
      expect(dates.contains(DateTime(2026, 6, 24)), isTrue);
    });

    test('a staff-removed date is dropped even without a cancellation request', () {
      // Staff "remove from day" creates a REMOVED assignment with no matching
      // date-change request; the dog should still disappear from that day.
      final dates = upcomingDaycareDates(
        now: now,
        daycareWeekdays: {1},
        requests: const [],
        staffRemovedDates: [DateTime(2026, 6, 22)],
      );
      expect(dates.contains(DateTime(2026, 6, 22)), isFalse);
      // Later Mondays are untouched.
      expect(dates.contains(DateTime(2026, 6, 29)), isTrue);
    });

    test('staff-removed dates are matched at day granularity', () {
      // A removed date carrying a time component still matches the midnight date.
      final dates = upcomingDaycareDates(
        now: now,
        daycareWeekdays: {1},
        requests: const [],
        staffRemovedDates: [DateTime(2026, 6, 22, 9, 30)],
      );
      expect(dates.contains(DateTime(2026, 6, 22)), isFalse);
    });

    test('added dates outside the window are excluded', () {
      // newDate well beyond three months should not appear.
      final dates = upcomingDaycareDates(
        now: now,
        daycareWeekdays: const {},
        requests: [
          _req(
            type: RequestType.addDay,
            status: RequestStatus.approved,
            newDate: DateTime(2027, 1, 1),
          ),
        ],
      );
      expect(dates.contains(DateTime(2027, 1, 1)), isFalse);
    });
  });
}
