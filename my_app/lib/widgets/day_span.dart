/// Calendar-day arithmetic that ignores the clock.
///
/// `end.difference(start).inDays` on two local midnights is one short across
/// the March clock change (the day is 23 hours long), so a two-night stay
/// read "1 night" and a one-night stay had no label at all; adding
/// `Duration(days: 7)` across the October change lands on 23:00 six days on.
/// Everything that counts days or nights, or steps by days, goes through
/// here instead.
library;

/// Whole calendar days from [start] to [end] (negative when [end] is
/// earlier), whatever time of day either carries.
int calendarDaysBetween(DateTime start, DateTime end) =>
    DateTime.utc(end.year, end.month, end.day)
        .difference(DateTime.utc(start.year, start.month, start.day))
        .inDays;

/// The nights of a stay from [start] to [end]: a stay from the 6th to the
/// 7th is one night.
int nightsBetween(DateTime start, DateTime end) => calendarDaysBetween(start, end);

/// Local midnight [days] calendar days after [date] (before, when negative).
DateTime addCalendarDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

/// "1 night" / "3 nights".
String nightsLabel(int nights) => nights == 1 ? '1 night' : '$nights nights';
