import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/widgets/day_span.dart';

void main() {
  // Mirrors what DateTime does in Europe/London without depending on the
  // machine's zone: a local day that is 23 or 25 hours long.
  group('calendarDaysBetween', () {
    test('counts across the March clock change', () {
      // 2026-03-29 is the last Sunday of March.
      expect(calendarDaysBetween(DateTime(2026, 3, 28), DateTime(2026, 3, 29)), 1);
      expect(calendarDaysBetween(DateTime(2026, 3, 28), DateTime(2026, 3, 30)), 2);
      expect(calendarDaysBetween(DateTime(2026, 3, 27), DateTime(2026, 4, 3)), 7);
    });

    test('counts across the October clock change', () {
      // 2026-10-25 is the last Sunday of October.
      expect(calendarDaysBetween(DateTime(2026, 10, 24), DateTime(2026, 10, 25)), 1);
      expect(calendarDaysBetween(DateTime(2026, 10, 24), DateTime(2026, 10, 26)), 2);
      expect(calendarDaysBetween(DateTime(2026, 10, 23), DateTime(2026, 10, 30)), 7);
    });

    test('ignores the time of day on either side', () {
      // 23 hours apart on the clock, one calendar day apart.
      expect(calendarDaysBetween(DateTime(2026, 3, 28, 23), DateTime(2026, 3, 29, 1)), 1);
      // 25 hours apart, still one.
      expect(calendarDaysBetween(DateTime(2026, 10, 24, 0), DateTime(2026, 10, 25, 23)), 1);
      expect(calendarDaysBetween(DateTime(2026, 5, 4, 18), DateTime(2026, 5, 4, 2)), 0);
    });

    test('is negative when the end is earlier', () {
      expect(calendarDaysBetween(DateTime(2026, 3, 30), DateTime(2026, 3, 28)), -2);
    });
  });

  group('addCalendarDays', () {
    test('a week on keeps the weekday across both clock changes', () {
      final march = addCalendarDays(DateTime(2026, 3, 25), 7);
      expect(march, DateTime(2026, 4, 1));
      expect(march.weekday, DateTime(2026, 3, 25).weekday);

      final october = addCalendarDays(DateTime(2026, 10, 21), 7);
      expect(october, DateTime(2026, 10, 28));
      expect(october.weekday, DateTime(2026, 10, 21).weekday);
      expect(october.hour, 0);
    });

    test('drops the time and rolls over months', () {
      expect(addCalendarDays(DateTime(2026, 1, 31, 15, 30), 1), DateTime(2026, 2, 1));
      expect(addCalendarDays(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    });
  });

  test('nightsLabel', () {
    expect(nightsLabel(1), '1 night');
    expect(nightsLabel(0), '0 nights');
    expect(nightsLabel(4), '4 nights');
  });
}
