import '../models/date_change_request.dart';

/// Pure, side-effect-free helpers for a dog's daycare schedule.
///
/// These were extracted verbatim from `DogHomeScreen` (audit item F15) so the
/// scheduling business logic can be unit-tested in isolation and reused without
/// dragging in widget/networking state. They take all their inputs explicitly
/// (including `now`) and never read the clock or touch any service.

/// True when request [a] supersedes request [b]: created later, with the
/// (numeric) id as a tie-break so two requests created in the same instant
/// still order stably.
bool requestSupersedes(DateChangeRequest a, DateChangeRequest b) {
  if (!a.createdAt.isAtSameMomentAs(b.createdAt)) {
    return a.createdAt.isAfter(b.createdAt);
  }
  final aId = int.tryParse(a.id);
  final bId = int.tryParse(b.id);
  if (aId != null && bId != null && aId != bId) return aId > bId;
  return a.id.compareTo(b.id) > 0;
}

/// Compute the dog's upcoming booked daycare dates, from today up to (but not
/// including) [monthsAhead] months from [now] (three by default).
///
/// Recurring days come from [daycareWeekdays] (1 = Monday ... 7 = Sunday).
/// Active (non-denied) [requests] adjust the set:
///  - cancellations and the *original* date of a change remove a date,
///  - additional days and the *new* date of a change add a date (only when it
///    falls within the [now, now + 3 months) window).
///
/// When several requests touch the same date, the most recent one wins — a
/// day can be cancelled and later added back (or added and then cancelled),
/// so no single request permanently vetoes the date. This mirrors the
/// server's roster projection.
///
/// [staffRemovedDates] are days staff have taken the dog off for the day
/// (server-side REMOVED assignments with no matching cancellation request).
/// They are dropped from the result so the profile matches the staff
/// dashboard. The server deletes these markers when a later re-add is
/// approved, so they always represent the latest word on their date.
///
/// The returned list is normalised to midnight and sorted ascending.
List<DateTime> upcomingDaycareDates({
  required DateTime now,
  required Set<int> daycareWeekdays,
  required List<DateChangeRequest> requests,
  Iterable<DateTime> staffRemovedDates = const [],
  int monthsAhead = 3,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final windowEnd = DateTime(now.year, now.month + monthsAhead, now.day);

  DateTime norm(DateTime d) => DateTime(d.year, d.month, d.day);
  bool isActive(DateChangeRequest r) => r.status != RequestStatus.denied;

  // For each date, keep only the latest active request touching it and
  // whether that request adds or removes the day. A change acts on two
  // dates: it removes its original date and adds its new date.
  final latestByDate = <DateTime, ({DateChangeRequest request, bool isAdd})>{};
  void consider(DateTime? raw, DateChangeRequest r, {required bool isAdd}) {
    if (raw == null) return;
    final day = norm(raw);
    final current = latestByDate[day];
    if (current == null || requestSupersedes(r, current.request)) {
      latestByDate[day] = (request: r, isAdd: isAdd);
    }
  }

  for (final r in requests.where(isActive)) {
    if (r.requestType == RequestType.cancel ||
        r.requestType == RequestType.change) {
      consider(r.originalDate, r, isAdd: false);
    }
    if (r.requestType == RequestType.addDay ||
        r.requestType == RequestType.change) {
      consider(r.newDate, r, isAdd: true);
    }
  }

  final removedDates = <DateTime>{};
  final addedDates = <DateTime>{};
  latestByDate.forEach((day, entry) {
    if (entry.isAdd) {
      // Added dates may fall on non-recurring weekdays; only surface the
      // ones inside the visible window.
      if (!day.isBefore(today) && day.isBefore(windowEnd)) addedDates.add(day);
    } else {
      removedDates.add(day);
    }
  });

  final dates = <DateTime>{};
  var current = today;
  while (current.isBefore(windowEnd)) {
    if (daycareWeekdays.contains(current.weekday)) {
      dates.add(norm(current));
    }
    current = current.add(const Duration(days: 1));
  }
  dates.addAll(addedDates);
  dates.removeAll(removedDates);

  // Staff "remove from day" actions create REMOVED assignments without a
  // cancellation request, so subtract them too — otherwise the profile keeps
  // showing the dog as booked on a day the dashboard has already dropped.
  dates.removeAll(staffRemovedDates.map(norm));

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

/// Earliest date selectable on the dog's daycare calendar.
///
/// Past days are attendance history that feeds invoicing, so only staff who
/// can manage payments may scroll back (a year, matching the server's
/// past-attendance window). Everyone else starts at today.
DateTime calendarFirstDay(DateTime now, {required bool canEditPastDates}) =>
    canEditPastDates
        ? DateTime(now.year - 1, now.month, now.day)
        : DateTime(now.year, now.month, now.day);
