import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:picons/picons.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../constants/app_colors.dart';
import '../../models/owner_calendar.dart';

enum CalendarViewMode { day, week, month }

/// The dashboard's Calendar: every one of the owner's dogs on one view,
/// by Day, Week or Month, swiping left and right — into the past too.
///
/// The section owns no data. It reads days through [dayFor] and tells the
/// dashboard what it is showing through [onVisibleRange], so the dashboard
/// can fetch months as they come into view (the calendar endpoint caps a
/// request at 92 days). A day with nothing loaded yet reads as loading.
class ClientCalendarSection extends StatefulWidget {
  final DateTime today;
  final List<CalendarDogRef> dogs;
  final CalendarDay? Function(DateTime day) dayFor;
  final void Function(DateTime start, DateTime end) onVisibleRange;

  /// Opens My Calendar on a day, where the waitlist actions live.
  final void Function(DateTime day)? onOpenDay;
  final CalendarViewMode initialMode;

  const ClientCalendarSection({
    super.key,
    required this.today,
    required this.dogs,
    required this.dayFor,
    required this.onVisibleRange,
    this.onOpenDay,
    this.initialMode = CalendarViewMode.week,
  });

  @override
  State<ClientCalendarSection> createState() => _ClientCalendarSectionState();
}

class _ClientCalendarSectionState extends State<ClientCalendarSection> {
  static final DateFormat _weekday = DateFormat('EEE');
  static final DateFormat _dayTitle = DateFormat('EEEE d MMMM');
  static final DateFormat _shortDate = DateFormat('d MMM');

  late CalendarViewMode _mode = widget.initialMode;

  /// The day whose details show under the week strip and month grid, and
  /// the day the Day view is on.
  late DateTime _selected = widget.today;

  /// Which month the month grid is showing.
  late DateTime _focused = widget.today;

  /// Which way the last swipe went, for the slide-in direction.
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportRange());
  }

  static DateTime _date(DateTime d) => DateTime(d.year, d.month, d.day);
  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  static DateTime _monday(DateTime d) => _date(d).subtract(Duration(days: d.weekday - 1));

  void _reportRange() {
    switch (_mode) {
      case CalendarViewMode.day:
        widget.onVisibleRange(_selected, _selected);
      case CalendarViewMode.week:
        final monday = _monday(_selected);
        widget.onVisibleRange(monday, monday.add(const Duration(days: 6)));
      case CalendarViewMode.month:
        // The grid pads the month out to whole weeks either side.
        final first = DateTime(_focused.year, _focused.month, 1);
        final last = DateTime(_focused.year, _focused.month + 1, 0);
        widget.onVisibleRange(
          first.subtract(const Duration(days: 6)),
          last.add(const Duration(days: 6)),
        );
    }
  }

  void _setMode(CalendarViewMode mode) {
    setState(() {
      _mode = mode;
      _focused = _selected;
    });
    _reportRange();
  }

  /// Day view: one day; week view: seven. Month swipes are the grid's own.
  void _step(int direction) {
    final days = _mode == CalendarViewMode.week ? 7 : 1;
    setState(() {
      _direction = direction;
      _selected = _selected.add(Duration(days: days * direction));
      _focused = _selected;
    });
    _reportRange();
  }

  void _jumpToToday() {
    setState(() {
      _direction = widget.today.isBefore(_selected) ? -1 : 1;
      _selected = widget.today;
      _focused = widget.today;
    });
    _reportRange();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Calendar',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            ),
            SegmentedButton<CalendarViewMode>(
              segments: const [
                ButtonSegment(value: CalendarViewMode.day, label: Text('Day')),
                ButtonSegment(value: CalendarViewMode.week, label: Text('Week')),
                ButtonSegment(value: CalendarViewMode.month, label: Text('Month')),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(theme.textTheme.labelSmall),
                padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
              ),
              onSelectionChanged: (selection) => _setMode(selection.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.antiAlias,
          child: switch (_mode) {
            CalendarViewMode.day => _swipeable(_buildDay()),
            CalendarViewMode.week => _swipeable(_buildWeek()),
            CalendarViewMode.month => _buildMonth(),
          },
        ),
      ],
    );
  }

  /// A horizontal swipe steps back or forward; the page slides in from the
  /// side it came from. No fixed height, so a busy day can be taller.
  Widget _swipeable(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -200) {
          _step(1);
        } else if (velocity > 200) {
          _step(-1);
        }
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) {
          final slide = Tween<Offset>(
            begin: Offset(0.25 * _direction, 0),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: slide, child: child),
          );
        },
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, if (current != null) current],
        ),
        child: KeyedSubtree(
          key: ValueKey('${_mode.name}-${_mode == CalendarViewMode.week ? _monday(_selected) : _date(_selected)}'),
          child: child,
        ),
      ),
    );
  }

  Widget _pageHeader(String title, {bool showToday = true}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Picon(PiconsRegular.caretLeft, size: 18),
            tooltip: 'Previous',
            visualDensity: VisualDensity.compact,
            onPressed: () => _step(-1),
          ),
          Expanded(
            child: Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          if (showToday && !_sameDay(_selected, widget.today) &&
              !(_mode == CalendarViewMode.week && _monday(_selected) == _monday(widget.today)))
            TextButton(
              onPressed: _jumpToToday,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('Today', style: TextStyle(fontSize: 12)),
            ),
          IconButton(
            icon: const Picon(PiconsRegular.caretRight, size: 18),
            tooltip: 'Next',
            visualDensity: VisualDensity.compact,
            onPressed: () => _step(1),
          ),
        ],
      ),
    );
  }

  // ── Day ───────────────────────────────────────────────────────────

  Widget _buildDay() {
    final isToday = _sameDay(_selected, widget.today);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pageHeader(isToday ? 'Today, ${_shortDate.format(_selected)}' : _dayTitle.format(_selected)),
        _DayPanel(
          day: _selected,
          info: widget.dayFor(_selected),
          dogs: widget.dogs,
          today: widget.today,
          onOpenDay: widget.onOpenDay,
        ),
      ],
    );
  }

  // ── Week ──────────────────────────────────────────────────────────

  Widget _buildWeek() {
    final monday = _monday(_selected);
    final sunday = monday.add(const Duration(days: 6));
    final title = monday.month == sunday.month
        ? '${monday.day} – ${_shortDate.format(sunday)}'
        : '${_shortDate.format(monday)} – ${_shortDate.format(sunday)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pageHeader(title),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(child: _chip(monday.add(Duration(days: i)))),
            ],
          ),
        ),
        const Divider(height: 1),
        _DayPanel(
          day: _selected,
          info: widget.dayFor(_selected),
          dogs: widget.dogs,
          today: widget.today,
          onOpenDay: widget.onOpenDay,
          compact: true,
        ),
      ],
    );
  }

  /// A day of the week strip: a dot per dog booked in (teal for daycare,
  /// purple for boarding), an amber dot for a request still waiting, and the
  /// day's closure or "full" state in place of the dots.
  Widget _chip(DateTime date) {
    final info = widget.dayFor(date);
    final closure = info?.closure;
    final dogs = info?.dogs ?? const <CalendarDogEntry>[];
    final pending = info?.pendingRequests.isNotEmpty ?? false;
    final full = (info?.isFull ?? false) && dogs.isEmpty;
    final isToday = _sameDay(date, widget.today);
    final isSelected = _sameDay(date, _selected);

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

    final scheme = Theme.of(context).colorScheme;
    final fg = isSelected ? Colors.white : scheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _selected = date),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: isToday && !isSelected ? Border.all(color: AppColors.primary, width: 1.5) : null,
            ),
            child: Column(
              children: [
                Text(_weekday.format(date),
                    style: TextStyle(fontSize: 10, color: isSelected ? fg : Colors.grey[600])),
                Text('${date.day}',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: fg)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(height: 14, child: Center(child: marker)),
        ],
      ),
    );
  }

  Widget _dot(Color color) => Container(
        width: 7,
        height: 7,
        margin: const EdgeInsets.symmetric(horizontal: 1.5),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  // ── Month ─────────────────────────────────────────────────────────

  List<Color> _markersFor(DateTime day) {
    final info = widget.dayFor(day);
    if (info == null) return const [];
    return [
      if (info.closure != null) AppColors.error,
      if (info.dogs.any((d) => !d.boarding)) AppColors.primary,
      if (info.dogs.any((d) => d.boarding)) Colors.deepPurple,
      if (info.pendingRequests.isNotEmpty) AppColors.warning,
    ];
  }

  Widget _buildMonth() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TableCalendar<Color>(
            firstDay: DateTime(widget.today.year - 2, 1, 1),
            lastDay: DateTime(widget.today.year + 1, 12, 31),
            focusedDay: _focused,
            currentDay: widget.today,
            selectedDayPredicate: (day) => _sameDay(_selected, day),
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selected = _date(selectedDay);
                _focused = focusedDay;
              });
            },
            onPageChanged: (focusedDay) {
              _focused = focusedDay;
              _reportRange();
            },
            eventLoader: _markersFor,
            calendarFormat: CalendarFormat.month,
            startingDayOfWeek: StartingDayOfWeek.monday,
            availableCalendarFormats: const {CalendarFormat.month: 'Month'},
            rowHeight: 42,
            daysOfWeekHeight: 20,
            headerStyle: const HeaderStyle(
              titleCentered: true,
              formatButtonVisible: false,
              titleTextStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            calendarStyle: const CalendarStyle(
              outsideDaysVisible: true,
              todayDecoration: BoxDecoration(
                color: Colors.transparent,
                shape: BoxShape.circle,
                border: Border.fromBorderSide(BorderSide(color: AppColors.primary, width: 1.5)),
              ),
              todayTextStyle: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold),
              selectedDecoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
            ),
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, markers) {
                if (markers.isEmpty) return null;
                return Positioned(
                  bottom: 2,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final color in markers.take(3))
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const Divider(height: 1),
        _DayPanel(
          day: _selected,
          info: widget.dayFor(_selected),
          dogs: widget.dogs,
          today: widget.today,
          onOpenDay: widget.onOpenDay,
          compact: true,
        ),
      ],
    );
  }
}

/// What's on for one day across all the owner's dogs: closure, each dog
/// booked in (daycare or boarding), requests waiting, waitlist places,
/// and the day's spare capacity.
class _DayPanel extends StatelessWidget {
  final DateTime day;
  final CalendarDay? info;
  final List<CalendarDogRef> dogs;
  final DateTime today;
  final void Function(DateTime day)? onOpenDay;
  final bool compact;

  const _DayPanel({
    required this.day,
    required this.info,
    required this.dogs,
    required this.today,
    this.onOpenDay,
    this.compact = false,
  });

  static final DateFormat _dayLabel = DateFormat('EEE d MMM');

  String _dogName(String dogId) {
    for (final dog in dogs) {
      if (dog.id == dogId) return dog.name;
    }
    return 'Your dog';
  }

  Widget _row(BuildContext context, {required PiconDuotoneData icon, required Color color,
      required String title, String? subtitle}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 4 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Picon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                if (subtitle != null)
                  Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    final rows = <Widget>[];
    if (info == null) {
      rows.add(_row(context,
          icon: PiconsDuotone.calendarBlank, color: AppColors.iosSecondaryLabel, title: 'Loading…'));
    } else {
      if (info.closure != null) {
        final closed = info.closure!.closureType.apiValue == 'CLOSED';
        rows.add(_row(context,
            icon: closed ? PiconsDuotone.prohibit : PiconsDuotone.warningCircle,
            color: closed ? AppColors.error : AppColors.warning,
            title: closed ? 'Closed' : 'Reduced capacity',
            subtitle: info.closure!.reason.isNotEmpty ? info.closure!.reason : null));
      }
      for (final dog in info.dogs) {
        rows.add(_row(context,
            icon: dog.boarding ? PiconsDuotone.bed : PiconsDuotone.pawPrint,
            color: dog.boarding ? Colors.deepPurple : AppColors.primary,
            title: dog.name,
            subtitle: dog.boarding ? 'Boarding' : 'Daycare'));
      }
      for (final request in info.pendingRequests) {
        final label = switch (request.requestType) {
          'ADD_DAY' => 'extra day requested',
          'CANCEL' => 'cancellation requested',
          _ => 'date change requested',
        };
        rows.add(_row(context,
            icon: PiconsDuotone.hourglass,
            color: AppColors.warning,
            title: '${_dogName(request.dogId)} — $label',
            subtitle: 'Waiting for staff approval'));
      }
      for (final entry in info.waitlist) {
        rows.add(_row(context,
            icon: PiconsDuotone.clockCounterClockwise,
            color: AppColors.iosSecondaryLabel,
            title: '${_dogName(entry.dogId)} — on the waitlist',
            subtitle: entry.status == 'NOTIFIED'
                ? 'A spot opened up! Request the day now.'
                : "We'll notify you if a spot opens."));
      }
      if (info.dogs.isEmpty && info.closure == null && info.pendingRequests.isEmpty) {
        final past = day.isBefore(today);
        rows.add(_row(context,
            icon: PiconsDuotone.calendarBlank,
            color: AppColors.iosSecondaryLabel,
            title: 'No bookings',
            subtitle: past
                ? null
                : info.isFull
                    ? 'This day is full.'
                    : "Request an extra day from your dog's profile."));
      }
    }

    String? footer;
    if (info != null && info.capacity != null && !day.isBefore(today)) {
      final taken = info.capacity! - (info.spotsLeft ?? 0);
      footer = info.isFull
          ? 'Full — $taken of ${info.capacity} spots taken'
          : '${info.spotsLeft} of ${info.capacity} spots still available';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact)
            Row(
              children: [
                Expanded(
                  child: Text(_dayLabel.format(day),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey[600])),
                ),
                if (onOpenDay != null)
                  TextButton(
                    onPressed: () => onOpenDay!(day),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('Details', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ...rows,
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(footer, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            ),
          if (!compact && onOpenDay != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => onOpenDay!(day),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('Open in My Calendar', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }
}
