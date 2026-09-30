import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:picons/picons.dart';
import 'package:table_calendar/table_calendar.dart';
import '../constants/app_colors.dart';
import '../models/closure_day.dart';
import '../models/invoice.dart';

/// Month calendar showing a dog's daycare schedule on their profile.
///
/// Renders the pre-agreed days (plus approved one-off changes) so owners and
/// staff can see at a glance when the dog is in, and tap days to make changes:
///  - tapping a booked day fires [onBookedDayTap] (cancel / move the day),
///  - tapping a free day fires [onFreeDayTap] (request / add an extra day).
///
/// Pending requests and facility closures are painted but not editable here —
/// tapping them explains why in a snackbar. Boarding stays are the same unless
/// [onBoardingDayTap] is set (staff), in which case tapping a boarding day
/// fires it so the covering stay can be cancelled. All date sets must be
/// normalised to midnight (the widget normalises its own lookups too).
class DogScheduleCalendar extends StatefulWidget {
  final DateTime firstDay;
  final DateTime lastDay;

  /// Booked daycare days (recurring days adjusted by approved requests).
  final Set<DateTime> bookedDates;

  /// The subset of [bookedDates] that are not one of the dog's regular
  /// weekdays — extra days added on top of the schedule. Drawn in teal
  /// ([AppColors.extraDay]) so they stand apart from the regular green days;
  /// they tap like any booked day.
  final Set<DateTime> extraDates;

  /// Days with a pending ADD_DAY (or the new date of a pending CHANGE).
  final Set<DateTime> pendingAddDates;

  /// Booked days with a pending CANCEL (or the original date of a CHANGE).
  final Set<DateTime> pendingRemoveDates;

  /// Days covered by an approved boarding request.
  final Set<DateTime> boardingDates;

  /// Days covered by a pending boarding request.
  final Set<DateTime> pendingBoardingDates;

  /// The nights of approved stays, keyed by the evening they start: a stay
  /// from the 6th to the 7th is the single night of the 6th. Both of its days
  /// stay coloured (the dog is in daycare on each), and each night is drawn as
  /// a small arc with a moon bridging its two days, so a one-night stay can't
  /// be mistaken for two.
  final Set<DateTime> boardingNights;

  /// The same for pending stays, drawn fainter.
  final Set<DateTime> pendingBoardingNights;

  /// Facility closures by date (CLOSED days block adding).
  final Map<DateTime, ClosureDay> closures;

  final bool isStaff;

  /// Payment managers may tap days before today too — past days are the
  /// attendance history invoicing bills from. Everyone else's taps on past
  /// days are ignored.
  final bool allowPastEdits;

  final void Function(DateTime date) onBookedDayTap;
  final void Function(DateTime date) onFreeDayTap;

  /// Staff handler for tapping a day covered by a boarding stay (approved or
  /// pending) so the stay can be cancelled. When null, tapping a boarding day
  /// just explains in a snackbar that boarding is managed elsewhere.
  final void Function(DateTime date)? onBoardingDayTap;

  /// Which invoice charges each day — payment managers only (the dog profile
  /// passes null for everyone else, and the API refuses them anyway). Days
  /// with an entry get a small dot coloured by the invoice's state, and a
  /// long-press names the invoice; [onInvoiceTap] opens it.
  final Map<DateTime, InvoiceCoverage>? invoiceCoverage;
  final void Function(InvoiceCoverage coverage)? onInvoiceTap;

  const DogScheduleCalendar({
    super.key,
    required this.firstDay,
    required this.lastDay,
    required this.bookedDates,
    this.extraDates = const {},
    required this.pendingAddDates,
    required this.pendingRemoveDates,
    required this.boardingDates,
    required this.pendingBoardingDates,
    this.boardingNights = const {},
    this.pendingBoardingNights = const {},
    required this.closures,
    required this.isStaff,
    this.allowPastEdits = false,
    required this.onBookedDayTap,
    required this.onFreeDayTap,
    this.onBoardingDayTap,
    this.invoiceCoverage,
    this.onInvoiceTap,
  });

  @override
  State<DogScheduleCalendar> createState() => _DogScheduleCalendarState();
}

class _DogScheduleCalendarState extends State<DogScheduleCalendar> {
  late DateTime _focusedDay;

  static const Color _booked = AppColors.success;
  static const Color _extra = AppColors.extraDay;
  static const Color _pending = AppColors.warning;
  static const Color _boarding = Colors.deepPurple;
  static const double _circleSize = 36;
  static const double _moonSize = 12;

  /// Taller than TableCalendar's default 52 so a night's moon fits above the
  /// day circles.
  static const double _rowHeight = 62;
  static const Color _invoicedPaid = Colors.white;
  static const Color _invoicedUnpaid = AppColors.warning;
  static const Color _invoicedOverdue = AppColors.error;
  static final Color _invoicedDraft = Colors.grey[400]!;

  bool get _showsInvoices => widget.invoiceCoverage != null;

  Color _coverageColor(InvoiceCoverage coverage) {
    if (coverage.isOverdue) return _invoicedOverdue;
    if (coverage.isPaid) return _invoicedPaid;
    if (coverage.isDraft) return _invoicedDraft;
    return _invoicedUnpaid;
  }

  /// Long-press: which invoice (if any) charges this day, with a way in.
  void _showInvoiceSheet(DateTime day) {
    final d = _norm(day);
    final coverage = widget.invoiceCoverage?[d];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(DateFormat('EEEE d MMMM yyyy').format(d),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (coverage == null)
              Text('Not on any invoice yet.', style: TextStyle(color: Colors.grey[700]))
            else ...[
              Text(coverage.label),
              const SizedBox(height: 4),
              Text(coverage.statusLabel,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: coverage.isOverdue ? AppColors.error : Colors.grey[700])),
              if (widget.onInvoiceTap != null) ...[
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    widget.onInvoiceTap!(coverage);
                  },
                  child: const Text('Open invoice'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

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

  static final DateFormat _stayDay = DateFormat('EEE d');
  static final DateFormat _stayDayMonth = DateFormat('EEE d MMM');

  /// "1 night, Mon 6 – Tue 7 Oct" for the approved stay covering [d], worked
  /// out from the run of [boardingNights] around it; null when it has none.
  String? _stayLabel(DateTime d) {
    DateTime shift(DateTime x, int days) => DateTime(x.year, x.month, x.day + days);
    var start = d;
    while (widget.boardingNights.contains(shift(start, -1))) {
      start = shift(start, -1);
    }
    var end = d;
    while (widget.boardingNights.contains(end)) {
      end = shift(end, 1);
    }
    final nights = end.difference(start).inDays;
    if (nights < 1) return null;
    final from = start.month == end.month ? _stayDay.format(start) : _stayDayMonth.format(start);
    return '${nights == 1 ? '1 night' : '$nights nights'}, $from – ${_stayDayMonth.format(end)}';
  }

  void _onDayTapped(DateTime day) {
    final d = _norm(day);
    if (d.isBefore(_norm(DateTime.now())) && !widget.allowPastEdits) return;

    final closure = widget.closures[d];
    if (widget.boardingDates.contains(d) ||
        widget.pendingBoardingDates.contains(d)) {
      if (widget.onBoardingDayTap != null) {
        widget.onBoardingDayTap!(d);
      } else if (widget.boardingDates.contains(d)) {
        final stay = _stayLabel(d);
        _snack(stay == null
            ? 'Boarding day — manage it from the boarding request.'
            : 'Boarding: $stay — manage it from the boarding request.');
      } else {
        _snack('A boarding request covering this day is awaiting approval.');
      }
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
    } else if (widget.extraDates.contains(d)) {
      fill = _extra;
      textColor = Colors.white;
    } else if (widget.bookedDates.contains(d)) {
      fill = _booked;
      textColor = Colors.white;
    } else if (_isClosed(d)) {
      fill = Theme.of(context).colorScheme.surfaceContainerHighest;
      textColor = Theme.of(context).colorScheme.onSurfaceVariant;
      decoration = TextDecoration.lineThrough;
    }

    final coverage = widget.invoiceCoverage?[d];
    final yesterday = DateTime(d.year, d.month, d.day - 1);
    final nightOut = _nightColor(d);
    final nightIn = _nightColor(yesterday);
    if (fill == null && border == null && !isToday && coverage == null &&
        nightOut == null && nightIn == null) {
      return null; // default rendering
    }

    final circle = Container(
      width: _circleSize,
      height: _circleSize,
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
    );
    final dayCell = _withNightArcs(d, Center(child: circle), nightIn: nightIn, nightOut: nightOut);
    if (coverage == null) return dayCell;
    // A small dot under the number says the day is on an invoice; its colour
    // says whether that invoice is paid, unpaid, overdue or still a draft.
    return _withNightArcs(d, Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          circle,
          Positioned(
            bottom: 3,
            child: Semantics(
              label: 'On ${coverage.label}, ${coverage.statusLabel}',
              child: Container(
                key: ValueKey('invoice-dot-${d.year}-${d.month}-${d.day}'),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _coverageColor(coverage),
                  border: Border.all(color: fill == null ? Colors.grey[600]! : Colors.white, width: 1),
                ),
              ),
            ),
          ),
        ],
      ),
    ), nightIn: nightIn, nightOut: nightOut);
  }

  /// The colour of the night starting on [evening]'s arc, or null when the
  /// dog isn't boarding that night.
  Color? _nightColor(DateTime evening) {
    if (widget.boardingNights.contains(evening)) return _boarding;
    if (widget.pendingBoardingNights.contains(evening)) {
      return _boarding.withValues(alpha: 0.45);
    }
    return null;
  }

  /// Lays a night's arc over the day cell: the half arriving from yesterday
  /// evening ([nightIn]) on the left, the half leaving for tonight
  /// ([nightOut]) on the right, with tonight's moon on top where the two
  /// cells meet. Each cell draws its own halves, so an arc wrapping from
  /// Sunday to Monday leaves one row and enters the next.
  Widget _withNightArcs(DateTime d, Widget cell, {Color? nightIn, Color? nightOut}) {
    if (nightIn == null && nightOut == null) return cell;
    // A Sunday night's moon would sit on the calendar's right edge; keep it
    // inside the Sunday cell instead.
    final wraps = d.weekday == DateTime.sunday;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _NightArcPainter(
                  circleRadius: _circleSize / 2,
                  arcIn: nightIn,
                  arcOut: nightOut,
                ),
              ),
            ),
          ),
          cell,
          if (nightOut != null)
            Positioned(
              key: ValueKey('night-${d.year}-${d.month}-${d.day}'),
              top: 0,
              left: wraps ? width - _moonSize : width - _moonSize / 2,
              child: IgnorePointer(
                child: Picon(PiconsDuotone.moon, size: _moonSize, color: nightOut),
              ),
            ),
        ],
      );
    });
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
          // TableCalendar computes its page range once from firstDay/lastDay;
          // when past editing unlocks after the async permission load the
          // range extends backwards, and without a new key the header chevron
          // would still refuse to page before the original firstDay.
          key: ValueKey((widget.firstDay, widget.lastDay)),
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
          onDayLongPressed: _showsInvoices ? (day, _) => _showInvoiceSheet(day) : null,
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
          rowHeight: _rowHeight,
          calendarStyle: const CalendarStyle(outsideDaysVisible: false),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            _legendDot(_booked, 'Regular day'),
            _legendDot(_extra, 'Extra day'),
            _legendDot(_pending, 'Pending', outlined: true),
            _legendDot(_boarding, 'Boarding'),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Picon(PiconsDuotone.moon, size: _moonSize, color: _boarding),
                const SizedBox(width: 4),
                Text('Night boarding', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
              ],
            ),
            _legendDot(Colors.grey[400]!, 'Closed'),
          ],
        ),
        if (_showsInvoices) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              _legendDot(_invoicedUnpaid, 'Invoiced', outlined: true),
              _legendDot(_invoicedOverdue, 'Overdue', outlined: true),
              _legendDot(Colors.grey[700]!, 'Paid', outlined: true),
              _legendDot(_invoicedDraft, 'Draft invoice', outlined: true),
            ],
          ),
        ],
        const SizedBox(height: 4),
        Text(
          widget.isStaff
              ? [
                  'Tap a booked day to cancel or move it, or a free day to add one.',
                  if (widget.onBoardingDayTap != null)
                    'Tap a boarding day to cancel the stay.',
                  if (widget.allowPastEdits)
                    'Past days can be edited too — changes update attendance used for invoicing.',
                  if (_showsInvoices)
                    'A dot under a day means it is on an invoice — long-press the day to see which.',
                ].join(' ')
              : 'Tap a booked day to request a cancellation or move, or a free day to request an extra day.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }
}

/// Half-arcs over a day cell for boarding nights: [arcIn] rises from the
/// left edge (yesterday's night) down to this day's circle, [arcOut] leaves
/// the circle for the right edge (tonight). Each is a quarter of an ellipse
/// centred on the cell boundary, so neighbouring cells' halves meet at the
/// top of the arc, under the moon.
class _NightArcPainter extends CustomPainter {
  final double circleRadius;
  final Color? arcIn;
  final Color? arcOut;

  _NightArcPainter({required this.circleRadius, this.arcIn, this.arcOut});

  /// How far from the circle's centre (horizontally) the arc lands on it.
  static const double _foot = 9;
  static const double _peak = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    // Where the arc meets the circle, on its upper shoulder.
    final footY = cy - math.sqrt(circleRadius * circleRadius - _foot * _foot);
    final width = size.width - 2 * _foot; // centre-to-centre, less both feet
    final height = 2 * (footY - _peak);
    if (width <= 0 || height <= 0) return;

    Paint pen(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    if (arcOut != null) {
      final rect = Rect.fromCenter(center: Offset(size.width, footY), width: width, height: height);
      canvas.drawArc(rect, math.pi, math.pi / 2, false, pen(arcOut!));
    }
    if (arcIn != null) {
      final rect = Rect.fromCenter(center: Offset(0, footY), width: width, height: height);
      canvas.drawArc(rect, -math.pi / 2, math.pi / 2, false, pen(arcIn!));
    }
  }

  @override
  bool shouldRepaint(_NightArcPainter old) =>
      old.arcIn != arcIn || old.arcOut != arcOut || old.circleRadius != circleRadius;
}
