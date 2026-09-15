import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants/app_colors.dart';
import '../../models/owner_calendar.dart';

/// The next seven days as a row of chips, read off the owner calendar: a dot
/// per dog booked in (teal for daycare, purple for boarding), an amber dot
/// for a request still waiting, and the day's closure or "full" state in
/// place of the dots. Tapping a day opens My Calendar on it.
class ClientWeekStrip extends StatelessWidget {
  final DateTime today;
  final OwnerCalendar calendar;
  final void Function(DateTime day)? onTap;

  const ClientWeekStrip({
    super.key,
    required this.today,
    required this.calendar,
    this.onTap,
  });

  static final DateFormat _weekday = DateFormat('EEE');

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  CalendarDay? _dayFor(DateTime date) =>
      calendar.days.where((d) => _sameDay(d.date, date)).firstOrNull;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Next 7 Days',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(child: _chip(context, today.add(Duration(days: i)), isToday: i == 0)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(BuildContext context, DateTime date, {required bool isToday}) {
    final info = _dayFor(date);
    final closure = info?.closure;
    final dogs = info?.dogs ?? const [];
    final pending = info?.pendingRequests.isNotEmpty ?? false;
    final full = (info?.isFull ?? false) && dogs.isEmpty;

    Widget marker;
    if (closure != null) {
      final closed = closure.closureType.apiValue == 'CLOSED';
      marker = Text(closed ? 'Closed' : 'Reduced',
          style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: closed ? AppColors.error : AppColors.warning));
    } else if (dogs.isEmpty && !pending) {
      marker = Text(full ? 'Full' : '—',
          style: TextStyle(fontSize: 9, color: Colors.grey[500]));
    } else {
      marker = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final d in dogs) _dot(d.boarding ? Colors.deepPurple : AppColors.primary),
          if (pending) _dot(AppColors.warning),
        ],
      );
    }

    final fg = isToday ? Colors.white : Theme.of(context).colorScheme.onSurface;
    final chip = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isToday ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text(_weekday.format(date),
                  style: TextStyle(fontSize: 10, color: isToday ? fg : Colors.grey[600])),
              Text('${date.day}',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: fg)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(height: 14, child: Center(child: marker)),
      ],
    );
    if (onTap == null) return chip;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onTap!(date),
      child: chip,
    );
  }

  Widget _dot(Color color) => Container(
        width: 7,
        height: 7,
        margin: const EdgeInsets.symmetric(horizontal: 1.5),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}
