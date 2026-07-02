/// Pure helper for deciding which staff are actually working on a date.
///
/// The backend's `available_staff/<date>` deliberately only excludes approved
/// day-offs (a regular non-working day must not block assignment), so on its
/// own it can't tell the day board who is off rota. Combining it with the
/// weekly pattern from `staff-availability/coverage/` gives the real answer:
/// working = on the rota for that weekday AND not on approved day off.
Set<int> workingStaffIds({
  required DateTime date,
  required Map<String, dynamic> coverage,
  required Set<int> notOnDayOff,
}) {
  // Coverage is keyed '1'..'7' matching isoweekday, same as DateTime.weekday.
  final day = coverage['${date.weekday}'];
  if (day is! Map) return notOnDayOff;
  final rota = <int>{
    for (final entry in (day['available'] as List? ?? []))
      if (entry is Map && entry['id'] is int) entry['id'] as int,
  };
  // Day-off data missing (failed load) → trust the rota alone.
  if (notOnDayOff.isEmpty) return rota;
  return rota.intersection(notOnDayOff);
}
