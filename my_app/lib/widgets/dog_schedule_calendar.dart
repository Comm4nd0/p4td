import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import '../constants/app_colors.dart';
import '../models/closure_day.dart';

/// Month calendar showing a dog's daycare schedule on their profile.
///
/// Renders the pre-agreed days (plus approved one-off changes) so owners and
/// staff can see at a glance when the dog is in, and tap days to make changes:
///  - tapping a booked day fires [onBookedDayTap] (cancel / move the day),
///  - tapping a free day fires [onFreeDayTap] (request / add an extra day).
///
/// Pending requests, boarding stays and facility closures are painted but not
/// editable here — tapping them explains why in a snackbar. All date sets must
/// be normalised to midnight (the widget normalises its own lookups too).
class DogScheduleCalendar extends StatefulWidget {
  final DateTime firstDay;
  final DateTime lastDay;

  /// Booked daycare days (recurring days adjusted by approved requests).
  final Set<DateTime> bookedDates;

  /// Days with a pending ADD_DAY (or the new date of a pending CHANGE).
  final Set<DateTime> pendingAddDates;

  /// Booked days with a pending CANCEL (or the original date of a CHANGE).
  final Set<DateTime> pendingRemoveDates;

  /// Days covered by an approved boarding request.
  final Set<DateTime> boardingDates;

  /// Days covered by a pending boarding request.
  final Set<DateTime> pendingBoardingDates;

  /// Facility closures by date (CLOSED days block adding).
  final Map<DateTime, ClosureDay> closures;

  final bool isStaff;

  /// Payment managers may tap days before today too — past days are the
  /// attendance history invoicing bills from. Everyone else's taps on past
  /// days are ignored.
  final bool allowPastEdits;

  final void Function(DateTime date) onBookedDayTap;
  final void Function(DateTime date) onFreeDayTap;

  const DogScheduleCalendar({
    super.key,
    required this.firstDay,
    required this.lastDay,
    required this.bookedDates,
    required this.pendingAddDates,
    required this.pendingRemoveDates,
    required this.boardingDates,
    required this.pendingBoardingDates,
    required this.closures,
    required this.isStaff,
    this.allowPastEdits = false,
    required this.onBookedDayTap,
    required this.onFreeDayTap,
  });

  @override
  State<DogScheduleCalendar> createState() => _DogScheduleCalendarState();
}

class _DogScheduleCalendarState extends State<DogScheduleCalendar> {
  late DateTime _focusedDay;

  static const Color _booked = AppColors.success;
  static const Color _pending = AppColors.warning;
  static const Color _boarding = Colors.deepPurple;

  @override
  void initState() {
    super.initState();
    // Open on today (clamped into range) — with past editing enabled firstDay
    // sits a year back, and the calendar must not open on last year.
    final today = _norm(DateTime.now());
    if (today.isBefore(widget.firstDay)) {
      _focusedDay = widget.firstDay;
    } else if (today.isAfter(widget.lastDay)) {
      _focusedDay = widget.lastDay;
    } else {
      _focusedDay = today;
    }
  }

  DateTime _norm(DateTime d) => DateTime(d.year, d.month, d.day);

  bool _isClosed(DateTime day) =>
      widget.closures[_norm(day)]?.closureType == ClosureType.closed;

  void _snack(String message) {
    // Replace any showing snackbar so rapid taps don't queue explanations.
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _onDayTapped(DateTime day) {
    final d = _norm(day);
    if (d.isBefore(_norm(DateTime.now())) && !widget.allowPastEdits) return;

    final closure = widget.closures[d];
    if (widget.boardingDates.contains(d)) {
      _snack('Boarding day — manage it from the boarding request.');
    } else if (widget.pendingBoardingDates.contains(d)) {
      _snack('A boarding request covering this day is awaiting approval.');
    } else if (widget.pendingRemoveDates.contains(d)) {
      _snack(widget.isStaff
          ? 'A change for this day is awaiting approval — see Requests.'
          : 'Your change for this day is awaiting staff approval.');
    } else if (widget.pendingAddDates.contains(d)) {
      _snack(widget.isStaff
          ? 'A request for this day is awaiting approval — see Requests.'
          : 'Your request for this day is awaiting staff approval.');
    } else if (widget.bookedDates.contains(d)) {
      widget.onBookedDayTap(d);
    } else if (closure?.closureType == ClosureType.closed) {
      final reason = closure!.reason.isNotEmpty ? ' (${closure.reason})' : '';
      _snack('The daycare is closed on this day$reason.');
    } else {
      widget.onFreeDayTap(d);
    }
  }

  Widget? _buildDay(BuildContext context, DateTime day, {required bool isToday}) {
    final d = _norm(day);

    Color? fill;
    Color? border;
    Color? textColor;
    TextDecoration? decoration;

    if (widget.boardingDates.contains(d)) {
      fill = _boarding;
      textColor = Colors.white;
    } else if (widget.pendingBoardingDates.contains(d)) {
      border = _boarding;
      textColor = _boarding;
    } else if (widget.pendingRemoveDates.contains(d)) {
      fill = _pending.withValues(alpha: 0.15);
      border = _pending;
      textColor = _pending;
      decoration = TextDecoration.lineThrough;
    } else if (widget.pendingAddDates.contains(d)) {
      border = _pending;
      textColor = _pending;
    } else if (widget.bookedDates.contains(d)) {
      fill = _booked;
      textColor = Colors.white;
    } else if (_isClosed(d)) {
      fill = Theme.of(context).colorScheme.surfaceContainerHighest;
      textColor = Theme.of(context).colorScheme.onSurfaceVariant;
      decoration = TextDecoration.lineThrough;
    }

    if (fill == null && border == null && !isToday) {
      return null; // default rendering
    }

    return Center(
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: border != null
              ? Border.all(color: border, width: 1.5)
              : (isToday && fill == null
                  ? Border.all(color: Theme.of(context).primaryColor, width: 1.5)
                  : null),
        ),
        alignment: Alignment.center,
        child: Text(
          '${day.day}',
          style: TextStyle(
            color: textColor ??
                (isToday ? Theme.of(context).primaryColor : null),
            fontWeight: FontWeight.w600,
            decoration: decoration,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label, {bool outlined = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: outlined ? null : color,
            shape: BoxShape.circle,
            border: outlined ? Border.all(color: color, width: 1.5) : null,
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TableCalendar(
          firstDay: widget.firstDay,
          lastDay: widget.lastDay,
          focusedDay: _focusedDay,
          startingDayOfWeek: StartingDayOfWeek.monday,
          calendarFormat: CalendarFormat.month,
          availableCalendarFormats: const {CalendarFormat.month: 'Month'},
          onDaySelected: (selectedDay, focusedDay) {
            setState(() => _focusedDay = focusedDay);
            _onDayTapped(selectedDay);
          },
          onPageChanged: (focusedDay) => _focusedDay = focusedDay,
          calendarBuilders: CalendarBuilders(
            defaultBuilder: (context, day, _) =>
                _buildDay(context, day, isToday: false),
            todayBuilder: (context, day, _) =>
                _buildDay(context, day, isToday: true),
          ),
          headerStyle: const HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
          ),
          calendarStyle: const CalendarStyle(outsideDaysVisible: false),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            _legendDot(_booked, 'Booked'),
            _legendDot(_pending, 'Pending', outlined: true),
            _legendDot(_boarding, 'Boarding'),
            _legendDot(Colors.grey[400]!, 'Closed'),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.isStaff
              ? (widget.allowPastEdits
                  ? 'Tap a booked day to cancel or move it, or a free day to add one. '
                      'Past days can be edited too — changes update attendance used for invoicing.'
                  : 'Tap a booked day to cancel or move it, or a free day to add one.')
              : 'Tap a booked day to request a cancellation or move, or a free day to request an extra day.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }
}
