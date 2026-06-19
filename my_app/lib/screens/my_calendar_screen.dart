import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:table_calendar/table_calendar.dart';
import '../constants/app_colors.dart';
import '../models/owner_calendar.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/app_sheets.dart';
import '../widgets/grouped_section.dart';

/// Month view of the caller's booked daycare days, boarding stays, closures
/// and full days — with a waitlist join/leave flow for full days.
class MyCalendarScreen extends StatefulWidget {
  const MyCalendarScreen({super.key});

  @override
  State<MyCalendarScreen> createState() => _MyCalendarScreenState();
}

class _MyCalendarScreenState extends State<MyCalendarScreen> {
  final DataService _dataService = getIt<DataService>();

  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  /// 'yyyy-MM-dd' → day payload, merged across fetched months.
  final Map<String, CalendarDay> _days = {};
  final Set<String> _loadedMonths = {};
  List<CalendarDogRef> _myDogs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMonth(_focusedDay);
  }

  String _dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  String _monthKey(DateTime day) => '${day.year}-${day.month}';

  Future<void> _loadMonth(DateTime month, {bool force = false}) async {
    final key = _monthKey(month);
    if (!force && _loadedMonths.contains(key)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final start = DateTime(month.year, month.month, 1);
      final end = DateTime(month.year, month.month + 1, 0);
      final calendar = await _dataService.getOwnerCalendar(start: start, end: end);
      if (!mounted) return;
      setState(() {
        _loadedMonths.add(key);
        _myDogs = calendar.dogs;
        for (final day in calendar.days) {
          _days[_dayKey(day.date)] = day;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _refresh() async {
    await _loadMonth(_focusedDay, force: true);
  }

  CalendarDay? _dayFor(DateTime day) => _days[_dayKey(day)];

  List<Color> _markersFor(DateTime day) {
    final info = _dayFor(day);
    if (info == null) return const [];
    final markers = <Color>[];
    if (info.closure != null) markers.add(AppColors.error);
    if (info.dogs.any((d) => !d.boarding)) markers.add(AppColors.primary);
    if (info.dogs.any((d) => d.boarding)) markers.add(Colors.deepPurple);
    if (info.pendingRequests.isNotEmpty) markers.add(AppColors.warning);
    if (info.waitlist.isNotEmpty) markers.add(AppColors.iosSecondaryLabel);
    return markers;
  }

  bool _isFuture(DateTime day) {
    final today = DateTime.now();
    return day.isAfter(DateTime(today.year, today.month, today.day));
  }

  Future<void> _joinWaitlist(CalendarDay info) async {
    final attendingIds = info.dogs.map((d) => d.id).toSet();
    final waitlistedIds = info.waitlist.map((w) => w.dogId).toSet();
    final eligible = _myDogs
        .where((d) => !attendingIds.contains(d.id) && !waitlistedIds.contains(d.id))
        .toList();
    if (eligible.isEmpty) return;

    CalendarDogRef? dog;
    if (eligible.length == 1) {
      dog = eligible.first;
    } else {
      dog = await showAppActionSheet<CalendarDogRef>(
        context,
        title: 'Join waitlist for ${ukDateWithDay(info.date)}',
        actions: [
          for (final d in eligible) AppSheetAction(label: d.name, value: d),
        ],
      );
    }
    if (dog == null || !mounted) return;

    try {
      await _dataService.joinWaitlist(dogId: dog.id, date: info.date);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${dog.name} is on the waitlist — we'll notify you if a spot opens."),
          backgroundColor: AppColors.success,
        ),
      );
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _leaveWaitlist(CalendarWaitlistEntry entry) async {
    try {
      await _dataService.leaveWaitlist(entry.id);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not leave the waitlist: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  String _dogName(String dogId) {
    for (final dog in _myDogs) {
      if (dog.id == dogId) return dog.name;
    }
    return 'Your dog';
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Widget _buildDayPanel() {
    final info = _dayFor(_selectedDay);
    final theme = Theme.of(context);
    final children = <Widget>[];

    if (info == null) {
      return GroupedSection(
        children: [
          ListTile(
            leading: const Picon(PiconsDuotone.calendarBlank, color: AppColors.iosSecondaryLabel),
            title: Text(_loading ? 'Loading…' : 'No information for this day'),
          ),
        ],
      );
    }

    if (info.closure != null) {
      final closed = info.closure!.closureType.apiValue == 'CLOSED';
      children.add(ListTile(
        leading: Picon(
          closed ? PiconsDuotone.prohibit : PiconsDuotone.warningCircle,
          color: closed ? AppColors.error : AppColors.warning,
        ),
        title: Text(closed ? 'Closed' : 'Reduced capacity'),
        subtitle: info.closure!.reason.isNotEmpty ? Text(info.closure!.reason) : null,
      ));
    }

    for (final dog in info.dogs) {
      children.add(ListTile(
        leading: Picon(
          dog.boarding ? PiconsDuotone.bed : PiconsDuotone.pawPrint,
          color: dog.boarding ? Colors.deepPurple : AppColors.primary,
        ),
        title: Text(dog.name),
        subtitle: Text(dog.boarding ? 'Boarding' : 'Daycare'),
      ));
    }

    for (final request in info.pendingRequests) {
      final label = switch (request.requestType) {
        'ADD_DAY' => 'Extra day requested',
        'CANCEL' => 'Cancellation requested',
        _ => 'Date change requested',
      };
      children.add(ListTile(
        leading: const Picon(PiconsDuotone.hourglass, color: AppColors.warning),
        title: Text('${_dogName(request.dogId)} — $label'),
        subtitle: const Text('Waiting for staff approval'),
      ));
    }

    for (final entry in info.waitlist) {
      children.add(ListTile(
        leading: const Picon(PiconsDuotone.clockCounterClockwise,
            color: AppColors.iosSecondaryLabel),
        title: Text('${_dogName(entry.dogId)} — on the waitlist'),
        subtitle: Text(entry.status == 'NOTIFIED'
            ? 'A spot opened up! Request the day now.'
            : "We'll notify you if a spot opens."),
        trailing: TextButton(
          onPressed: () => _leaveWaitlist(entry),
          child: const Text('Leave'),
        ),
      ));
    }

    if (info.dogs.isEmpty && info.closure == null && info.pendingRequests.isEmpty) {
      children.add(ListTile(
        leading: Picon(PiconsDuotone.calendarBlank, color: AppColors.iosSecondaryLabel),
        title: const Text('No bookings'),
        subtitle: Text(
          info.isFull
              ? 'This day is currently full.'
              : "Request an extra day from your dog's profile.",
        ),
      ));
    }

    final canJoinWaitlist = info.isFull &&
        _isFuture(info.date) &&
        info.closure?.closureType.apiValue != 'CLOSED' &&
        _myDogs.any((d) =>
            !info.dogs.any((a) => a.id == d.id) &&
            !info.waitlist.any((w) => w.dogId == d.id));
    if (canJoinWaitlist) {
      children.add(ListTile(
        leading: const Picon(PiconsDuotone.listPlus, color: AppColors.primary),
        title: const Text('Day full — join the waitlist'),
        subtitle: const Text("Be notified the moment a spot opens up."),
        trailing: FilledButton(
          onPressed: () => _joinWaitlist(info),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            textStyle: theme.textTheme.titleSmall,
          ),
          child: const Text('Join'),
        ),
      ));
    }

    String? footer;
    if (info.capacity != null) {
      final taken = info.capacity! - (info.spotsLeft ?? 0);
      footer = info.isFull
          ? 'This day is full ($taken of ${info.capacity} spots taken).'
          : '${info.spotsLeft} of ${info.capacity} spots still available.';
    }

    return GroupedSection(
      header: ukDateWithDay(_selectedDay),
      footer: footer,
      children: children,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Calendar')),
      body: RefreshIndicator.adaptive(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Could not load calendar: $_error',
                  style: const TextStyle(color: AppColors.error),
                  textAlign: TextAlign.center,
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TableCalendar<Color>(
                firstDay: DateTime.now().subtract(const Duration(days: 365)),
                lastDay: DateTime.now().add(const Duration(days: 365)),
                focusedDay: _focusedDay,
                selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                onDaySelected: (selectedDay, focusedDay) {
                  setState(() {
                    _selectedDay = selectedDay;
                    _focusedDay = focusedDay;
                  });
                },
                onPageChanged: (focusedDay) {
                  _focusedDay = focusedDay;
                  _loadMonth(focusedDay);
                },
                eventLoader: _markersFor,
                calendarFormat: CalendarFormat.month,
                startingDayOfWeek: StartingDayOfWeek.monday,
                availableCalendarFormats: const {CalendarFormat.month: 'Month'},
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
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: color,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                alignment: WrapAlignment.center,
                children: [
                  _legendDot(AppColors.primary, 'Daycare'),
                  _legendDot(Colors.deepPurple, 'Boarding'),
                  _legendDot(AppColors.warning, 'Pending'),
                  _legendDot(AppColors.error, 'Closure'),
                  _legendDot(AppColors.iosSecondaryLabel, 'Waitlist'),
                ],
              ),
            ),
            _buildDayPanel(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
