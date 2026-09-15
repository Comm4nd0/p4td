import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../../constants/app_colors.dart';
import '../../models/owner_calendar.dart';
import '../../utils/date_formats.dart';

enum TodayStatus { daycare, boarding, home }

/// One dog's day, distilled from the owner calendar: what it is doing today,
/// when it is next booked in, and whether any request on it is still waiting.
class DogTodaySummary {
  final CalendarDogRef dog;
  final TodayStatus status;
  final DateTime? nextDate;
  final bool nextIsBoarding;
  final int pendingRequests;

  const DogTodaySummary({
    required this.dog,
    required this.status,
    this.nextDate,
    this.nextIsBoarding = false,
    this.pendingRequests = 0,
  });

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Summarise every dog on [calendar] against [today]. The calendar starts
  /// on today, so "next" is simply the first later day the dog appears on.
  static List<DogTodaySummary> fromCalendar(OwnerCalendar calendar, DateTime today) {
    final days = [...calendar.days]..sort((a, b) => a.date.compareTo(b.date));
    final todayDay = days.where((d) => _sameDay(d.date, today)).firstOrNull;
    return [for (final dog in calendar.dogs) _forDog(dog, days, todayDay, today)];
  }

  static DogTodaySummary _forDog(
    CalendarDogRef dog,
    List<CalendarDay> days,
    CalendarDay? todayDay,
    DateTime today,
  ) {
    final entry = todayDay?.dogs.where((e) => e.id == dog.id).firstOrNull;
    final status = entry == null
        ? TodayStatus.home
        : entry.boarding
            ? TodayStatus.boarding
            : TodayStatus.daycare;
    CalendarDay? nextDay;
    CalendarDogEntry? nextEntry;
    for (final day in days) {
      if (!day.date.isAfter(today)) continue;
      final e = day.dogs.where((e) => e.id == dog.id).firstOrNull;
      if (e != null) {
        nextDay = day;
        nextEntry = e;
        break;
      }
    }
    // A CHANGE request is listed on both of its dates; count it once.
    final pendingIds = <int>{
      for (final day in days)
        for (final r in day.pendingRequests)
          if (r.dogId == dog.id) r.id,
    };
    return DogTodaySummary(
      dog: dog,
      status: status,
      nextDate: nextDay?.date,
      nextIsBoarding: nextEntry?.boarding ?? false,
      pendingRequests: pendingIds.length,
    );
  }
}

/// The top of the client dashboard: today's date, any closure in force, and
/// a row per dog saying where it is today and when it is next in.
///
/// Pure presentation over the owner calendar. The clock is injected because
/// every assertion here is about "today" — an unpinned date would make the
/// tests pass on every day but the one they name.
class ClientTodaySection extends StatelessWidget {
  final DateTime today;
  final OwnerCalendar calendar;

  /// Profile image URL by dog id, from the dogs list the home screen already
  /// holds. A dog with no entry (or a null URL) shows its initial instead.
  final Map<String, String?> imageUrls;

  final void Function(CalendarDogRef dog)? onOpenDog;
  final VoidCallback? onOpenCalendar;

  const ClientTodaySection({
    super.key,
    required this.today,
    required this.calendar,
    this.imageUrls = const {},
    this.onOpenDog,
    this.onOpenCalendar,
  });

  bool get _isWeekend =>
      today.weekday == DateTime.saturday || today.weekday == DateTime.sunday;

  CalendarDay? get _todayDay => calendar.days
      .where((d) => DogTodaySummary._sameDay(d.date, today))
      .firstOrNull;

  int get _horizonDays => calendar.end.difference(today).inDays;

  @override
  Widget build(BuildContext context) {
    final summaries = DogTodaySummary.fromCalendar(calendar, today);
    final closure = _todayDay?.closure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Today',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text(ukDateWithDay(today),
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
            if (onOpenCalendar != null)
              TextButton.icon(
                onPressed: onOpenCalendar,
                icon: const Picon(PiconsDuotone.calendarCheck, size: 16),
                label: const Text('My Calendar'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (closure != null) ...[
          _ClosureBanner(closure: closure),
          const SizedBox(height: 8),
        ],
        if (summaries.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  'Your dogs will appear here once your booking form has been approved.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[500]),
                ),
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < summaries.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _DogRow(
                    summary: summaries[i],
                    imageUrl: imageUrls[summaries[i].dog.id],
                    isWeekend: _isWeekend,
                    horizonDays: _horizonDays,
                    onTap: onOpenDog == null ? null : () => onOpenDog!(summaries[i].dog),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ClosureBanner extends StatelessWidget {
  final CalendarClosure closure;
  const _ClosureBanner({required this.closure});

  @override
  Widget build(BuildContext context) {
    final closed = closure.closureType.apiValue == 'CLOSED';
    final color = closed ? AppColors.error : AppColors.warning;
    return Card(
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Picon(PiconsDuotone.warning, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(closed ? 'Closed today' : 'Reduced capacity today',
                      style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                  if (closure.reason.isNotEmpty)
                    Text(closure.reason, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DogRow extends StatelessWidget {
  final DogTodaySummary summary;
  final String? imageUrl;
  final bool isWeekend;
  final int horizonDays;
  final VoidCallback? onTap;

  const _DogRow({
    required this.summary,
    required this.imageUrl,
    required this.isWeekend,
    required this.horizonDays,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (statusIcon, statusColor, statusText) = switch (summary.status) {
      TodayStatus.daycare => (PiconsDuotone.pawPrint, AppColors.primary, 'In daycare today'),
      TodayStatus.boarding => (PiconsDuotone.bed, Colors.deepPurple, 'Boarding with us'),
      TodayStatus.home => (
          PiconsDuotone.houseLine,
          Colors.grey,
          isWeekend ? 'Home for the weekend' : 'At home today',
        ),
    };
    final next = summary.nextDate;
    final nextText = next == null
        ? 'Nothing booked in the next $horizonDays days'
        : 'Next in: ${ukDateWithDay(next)}${summary.nextIsBoarding ? ' (boarding)' : ''}';
    final name = summary.dog.name;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.primary.withValues(alpha: 0.15),
            backgroundImage: imageUrl != null ? CachedNetworkImageProvider(imageUrl!) : null,
            child: imageUrl == null
                ? Text(initial,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primary))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 3),
                Row(children: [
                  Picon(statusIcon, size: 14, color: statusColor),
                  const SizedBox(width: 6),
                  Text(statusText, style: TextStyle(fontSize: 13, color: statusColor)),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  Picon(PiconsDuotone.calendarBlank, size: 12, color: Colors.grey[600]),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(nextText,
                        style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                  ),
                ]),
                if (summary.pendingRequests > 0) ...[
                  const SizedBox(height: 2),
                  Row(children: [
                    const Picon(PiconsDuotone.hourglass, size: 12, color: AppColors.warning),
                    const SizedBox(width: 6),
                    Text(
                      summary.pendingRequests == 1
                          ? '1 request awaiting approval'
                          : '${summary.pendingRequests} requests awaiting approval',
                      style: const TextStyle(fontSize: 12, color: AppColors.warning),
                    ),
                  ]),
                ],
              ],
            ),
          ),
          if (onTap != null) Picon(PiconsDuotone.caretRight, size: 16, color: Colors.grey[400]),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}
