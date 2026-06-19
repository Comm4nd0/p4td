import '../models/date_change_request.dart';

/// Pure, side-effect-free helpers for a dog's daycare schedule.
///
/// These were extracted verbatim from `DogHomeScreen` (audit item F15) so the
/// scheduling business logic can be unit-tested in isolation and reused without
/// dragging in widget/networking state. They take all their inputs explicitly
/// (including `now`) and never read the clock or touch any service.

/// Compute the dog's upcoming booked daycare dates, from today up to (but not
/// including) three months from [now].
///
/// Recurring days come from [daycareWeekdays] (1 = Monday ... 7 = Sunday).
/// Active (non-denied) [requests] adjust the set:
///  - cancellations and the *original* date of a change remove a date,
///  - additional days and the *new* date of a change add a date (only when it
///    falls within the [now, now + 3 months) window).
///
/// The returned list is normalised to midnight and sorted ascending.
List<DateTime> upcomingDaycareDates({
  required DateTime now,
  required Set<int> daycareWeekdays,
  required List<DateChangeRequest> requests,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final threeMonthsLater = DateTime(now.year, now.month + 3, now.day);

  DateTime norm(DateTime d) => DateTime(d.year, d.month, d.day);
  bool isActive(DateChangeRequest r) => r.status != RequestStatus.denied;

  // Dates removed from the schedule: cancellations and the *original* date of
  // a change (a change moves a day from its original date to its new date).
  final removedDates = requests
      .where((r) =>
          isActive(r) &&
          (r.requestType == RequestType.cancel ||
              r.requestType == RequestType.change) &&
          r.originalDate != null)
      .map((r) => norm(r.originalDate!))
      .toSet();

  // Dates added to the schedule: additional days and the *new* date of a
  // change. These may fall on non-recurring weekdays, so add them explicitly.
  final addedDates = requests
      .where((r) =>
          isActive(r) &&
          (r.requestType == RequestType.addDay ||
              r.requestType == RequestType.change) &&
          r.newDate != null)
      .map((r) => norm(r.newDate!))
      .where((d) => !d.isBefore(today) && d.isBefore(threeMonthsLater))
      .toSet();

  final dates = <DateTime>{};
  var current = today;
  while (current.isBefore(threeMonthsLater)) {
    if (daycareWeekdays.contains(current.weekday)) {
      dates.add(norm(current));
    }
    current = current.add(const Duration(days: 1));
  }
  dates.addAll(addedDates);
  dates.removeAll(removedDates);

  final result = dates.toList()..sort();
  return result;
}

/// Whether [date] is "confirmed" — i.e. within one month of [now].
///
/// Confirmed dates can no longer be changed free of charge; the owner will
/// still be charged for them.
bool isDateConfirmed(DateTime date, {required DateTime now}) {
  final oneMonthLater = DateTime(now.year, now.month + 1, now.day);
  return date.isBefore(oneMonthLater);
}

/// Latest date selectable on the dog's daycare calendar.
///
/// Staff can edit which days a dog is at (or not at) daycare effectively
/// without limit — years into the future. Owners are still capped a few
/// months ahead, since their changes are *requests* that staff must approve.
DateTime calendarLastDay(DateTime now, {required bool isStaff}) => isStaff
    ? DateTime(now.year + 5, now.month, now.day)
    : DateTime(now.year, now.month + 3, now.day);
