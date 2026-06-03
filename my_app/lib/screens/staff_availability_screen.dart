import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:table_calendar/table_calendar.dart';
import '../constants/app_colors.dart';
import '../utils/date_formats.dart';
import '../models/day_off_request.dart';
import '../services/data_service.dart';

class StaffAvailabilityScreen extends StatefulWidget {
  final bool canAssignDogs;
  final bool canApproveTimeoff;
  const StaffAvailabilityScreen({super.key, required this.canAssignDogs, this.canApproveTimeoff = false});

  @override
  State<StaffAvailabilityScreen> createState() => _StaffAvailabilityScreenState();
}

class _StaffAvailabilityScreenState extends State<StaffAvailabilityScreen> with SingleTickerProviderStateMixin {
  final DataService _dataService = ApiDataService();
  late TabController _tabController;

  // My Availability tab
  Map<int, bool> _myAvailability = {};
  Map<int, String> _myNotes = {};
  bool _loadingMy = true;
  bool _saving = false;

  // Day Off Requests
  List<DayOffRequest> _myDayOffRequests = [];
  List<DayOffRequest> _allDayOffRequests = [];
  bool _loadingDayOff = true;

  // Coverage tab
  Map<String, dynamic> _coverage = {};
  bool _loadingCoverage = true;

  // Team Calendar tab (visible to all staff)
  Map<DateTime, List<String>> _teamOff = {};
  bool _loadingTeamOff = true;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  static const _dayNames = {
    1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday',
    5: 'Friday',
  };

  int get _tabCount {
    // Everyone sees: My Availability, Time Off, Team Calendar.
    // Managers also get Team Coverage.
    return widget.canAssignDogs ? 4 : 3;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabCount, vsync: this);
    _selectedDay = _focusedDay;
    _loadMyAvailability();
    _loadDayOffRequests();
    _loadTeamOff(_focusedDay);
    if (widget.canAssignDogs) _loadCoverage();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadMyAvailability() async {
    setState(() => _loadingMy = true);
    try {
      final avail = await _dataService.getMyAvailability();
      final availability = <int, bool>{};
      final notes = <int, String>{};
      for (final a in avail) {
        availability[a.dayOfWeek] = a.isAvailableDaycare;
        notes[a.dayOfWeek] = a.note;
      }
      for (int i = 1; i <= 5; i++) {
        availability.putIfAbsent(i, () => true);
        notes.putIfAbsent(i, () => '');
      }
      if (mounted) {
        setState(() {
          _myAvailability = availability;
          _myNotes = notes;
          _loadingMy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingMy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load availability: $e')),
        );
      }
    }
  }

  Future<void> _loadDayOffRequests() async {
    setState(() => _loadingDayOff = true);
    try {
      final myRequests = await _dataService.getMyDayOffRequests();
      List<DayOffRequest> allRequests = [];
      if (widget.canApproveTimeoff) {
        allRequests = await _dataService.getAllDayOffRequests();
      }
      if (mounted) {
        setState(() {
          _myDayOffRequests = myRequests;
          _allDayOffRequests = allRequests;
          _loadingDayOff = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingDayOff = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load day off requests: $e')),
        );
      }
    }
  }

  Future<void> _loadCoverage() async {
    setState(() => _loadingCoverage = true);
    try {
      final coverage = await _dataService.getStaffCoverage();
      if (mounted) setState(() { _coverage = coverage; _loadingCoverage = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingCoverage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load coverage: $e')),
        );
      }
    }
  }

  Future<void> _saveMyAvailability() async {
    setState(() => _saving = true);
    try {
      final data = <Map<String, dynamic>>[];
      for (int i = 1; i <= 5; i++) {
        data.add({
          'day_of_week': i,
          'is_available': _myAvailability[i] ?? true,
          'note': _myNotes[i] ?? '',
        });
      }
      await _dataService.setMyAvailability(data);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Availability saved'), backgroundColor: AppColors.success),
        );
      }
      if (widget.canAssignDogs) _loadCoverage();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Availability'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.cream,
          unselectedLabelColor: AppColors.cream.withAlpha(180),
          indicatorColor: AppColors.cream,
          isScrollable: _tabCount > 2,
          tabs: [
            const Tab(text: 'My Availability'),
            const Tab(text: 'Time Off'),
            const Tab(text: 'Team Calendar'),
            if (widget.canAssignDogs) const Tab(text: 'Team Coverage'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMyAvailabilityTab(),
          _buildDayOffTab(),
          _buildTeamCalendarTab(),
          if (widget.canAssignDogs) _buildCoverageTab(),
        ],
      ),
    );
  }

  // ── My Availability Tab (Simple Mon-Fri) ────────────────────────────

  Widget _buildMyAvailabilityTab() {
    if (_loadingMy) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Set your regular working days',
                style: TextStyle(fontSize: 14, color: AppColors.grey600),
              ),
              const SizedBox(height: 16),
              ...List.generate(5, (index) {
                final day = index + 1; // 1=Monday .. 5=Friday
                final isAvailable = _myAvailability[day] ?? true;
                final note = _myNotes[day] ?? '';

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    children: [
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isAvailable
                              ? AppColors.success.withAlpha(30)
                              : AppColors.grey200,
                          child: Picon(
                            isAvailable ? PiconsDuotone.check : PiconsDuotone.x,
                            color: isAvailable ? AppColors.success : AppColors.grey500,
                          ),
                        ),
                        title: Text(
                          _dayNames[day]!,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                        ),
                        subtitle: note.isNotEmpty
                            ? Text(note, style: TextStyle(fontSize: 13, color: AppColors.grey600))
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Picon(PiconsDuotone.pencilSimple, color: AppColors.grey500),
                              onPressed: () => _editNote(day),
                              tooltip: 'Edit note',
                            ),
                            Switch(
                              value: isAvailable,
                              onChanged: (val) {
                                setState(() => _myAvailability[day] = val);
                              },
                              activeColor: AppColors.success,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),

        // Save button
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _saveMyAvailability,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Picon(PiconsDuotone.floppyDisk),
              label: const Text('Save Availability'),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editNote(int day) async {
    final controller = TextEditingController(text: _myNotes[day]);
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${_dayNames[day]} Note'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'e.g. Available mornings only',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (note != null) {
      setState(() => _myNotes[day] = note.trim());
    }
  }

  // ── Day Off Requests Tab ────────────────────────────────────────────

  Widget _buildDayOffTab() {
    if (_loadingDayOff) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _loadDayOffRequests,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Request a day off button
          FilledButton.icon(
            onPressed: _showRequestDayOffDialog,
            icon: Picon(PiconsDuotone.plus),
            label: const Text('Request Day Off'),
          ),
          const SizedBox(height: 16),

          // My requests
          if (_myDayOffRequests.isNotEmpty) ...[
            const Text(
              'My Requests',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            ..._myDayOffRequests.map((r) => _buildMyDayOffCard(r)),
            const SizedBox(height: 16),
          ],

          if (_myDayOffRequests.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  Picon(PiconsDuotone.calendarCheck, size: 48, color: AppColors.grey400),
                  const SizedBox(height: 8),
                  Text(
                    'No day off requests',
                    style: TextStyle(color: AppColors.grey600),
                  ),
                ],
              ),
            ),

          // Pending approvals (staff with approve permission)
          if (widget.canApproveTimeoff) ...[
            _buildPendingApprovals(),
          ],
        ],
      ),
    );
  }

  Widget _buildMyDayOffCard(DayOffRequest request) {
    final dateStr = ukDateWithDay(request.date);
    final isPast = request.date.isBefore(DateTime.now().subtract(const Duration(days: 1)));

    Color statusColor;
    PiconDuotoneData statusIcon;
    switch (request.status) {
      case DayOffStatus.pending:
        statusColor = AppColors.warning;
        statusIcon = PiconsDuotone.hourglass;
      case DayOffStatus.approved:
        statusColor = AppColors.success;
        statusIcon = PiconsDuotone.checkCircle;
      case DayOffStatus.denied:
        statusColor = AppColors.error;
        statusIcon = PiconsDuotone.xCircle;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withAlpha(30),
          child: Picon(statusIcon, color: statusColor),
        ),
        title: Text(dateStr),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(request.status.displayName, style: TextStyle(color: statusColor, fontWeight: FontWeight.w600, fontSize: 12)),
            if (request.reason.isNotEmpty)
              Text(request.reason, style: TextStyle(fontSize: 12, color: AppColors.grey600)),
            if (request.reviewedBy != null)
              Text(
                '${request.status == DayOffStatus.approved ? 'Approved' : 'Denied'} by ${request.reviewedBy}',
                style: TextStyle(fontSize: 11, color: AppColors.grey500),
              ),
          ],
        ),
        trailing: (request.status == DayOffStatus.pending && !isPast)
            ? IconButton(
                icon: Picon(PiconsDuotone.x, size: 20),
                onPressed: () => _cancelDayOffRequest(request),
                tooltip: 'Cancel request',
              )
            : null,
      ),
    );
  }

  Widget _buildPendingApprovals() {
    final pendingRequests = _allDayOffRequests
        .where((r) => r.status == DayOffStatus.pending)
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text(
              'Pending Approvals',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            if (pendingRequests.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(30),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${pendingRequests.length}',
                  style: const TextStyle(fontSize: 12, color: AppColors.warning, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        if (pendingRequests.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('No pending requests', style: TextStyle(color: AppColors.grey500)),
          ),
        ...pendingRequests.map((r) => _buildApprovalCard(r)),
      ],
    );
  }

  Widget _buildApprovalCard(DayOffRequest request) {
    final dateStr = ukDateWithDay(request.date);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppColors.warning.withAlpha(30),
                  radius: 18,
                  child: Picon(PiconsDuotone.user, color: AppColors.warning, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.staffMemberName,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      Text(dateStr, style: TextStyle(fontSize: 13, color: AppColors.grey600)),
                    ],
                  ),
                ),
              ],
            ),
            if (request.reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(request.reason, style: TextStyle(fontSize: 13, color: AppColors.grey600)),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _denyDayOffRequest(request),
                  icon: Picon(PiconsDuotone.x, size: 18),
                  label: const Text('Deny'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _approveDayOffRequest(request),
                  icon: Picon(PiconsDuotone.check, size: 18),
                  label: const Text('Approve'),
                  style: FilledButton.styleFrom(backgroundColor: AppColors.success),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRequestDayOffDialog() async {
    final now = DateTime.now();
    final pickedRange = await showDateRangePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Select day(s) off',
      saveText: 'NEXT',
    );

    if (pickedRange == null || !mounted) return;

    final start = pickedRange.start;
    final end = pickedRange.end;
    final isSingle = start.year == end.year && start.month == end.month && start.day == end.day;

    final dateLabel = isSingle
        ? ukDateWithDay(start)
        : '${ukDate(start)} - ${ukDate(end)}';

    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Request $dateLabel Off'),
        content: TextField(
          controller: reasonController,
          decoration: const InputDecoration(
            hintText: 'Reason (optional)',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 2,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Submit Request')),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        // Create one request per date in the range
        final reason = reasonController.text.trim().isNotEmpty ? reasonController.text.trim() : null;
        var current = start;
        while (!current.isAfter(end)) {
          await _dataService.requestDayOff(date: current, reason: reason);
          current = current.add(const Duration(days: 1));
        }
        if (mounted) {
          final count = end.difference(start).inDays + 1;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isSingle
                  ? 'Day off request submitted'
                  : '$count day off requests submitted'),
              backgroundColor: AppColors.success,
            ),
          );
        }
        _loadDayOffRequests();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to request day off: $e')),
          );
        }
      }
    }
  }

  Future<void> _cancelDayOffRequest(DayOffRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Request'),
        content: Text('Cancel your day off request for ${ukDateWithDay(request.date)}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yes, Cancel')),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await _dataService.cancelDayOffRequest(request.id);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request cancelled')),
        );
        _loadDayOffRequests();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to cancel: $e')),
          );
        }
      }
    }
  }

  Future<void> _approveDayOffRequest(DayOffRequest request) async {
    try {
      await _dataService.approveDayOffRequest(request.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Approved day off for ${request.staffMemberName}'),
            backgroundColor: AppColors.success,
          ),
        );
      }
      _loadDayOffRequests();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to approve: $e')),
        );
      }
    }
  }

  Future<void> _denyDayOffRequest(DayOffRequest request) async {
    try {
      await _dataService.denyDayOffRequest(request.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Denied day off for ${request.staffMemberName}'),
          ),
        );
      }
      _loadDayOffRequests();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to deny: $e')),
        );
      }
    }
  }

  // ── Team Calendar Tab (all staff) ───────────────────────────────────

  Future<void> _loadTeamOff(DateTime month, {bool showSpinner = true}) async {
    // On month swipes we skip the spinner (and the synchronous setState that
    // would fight table_calendar's page animation) — markers just refresh when
    // the data arrives.
    if (showSpinner) setState(() => _loadingTeamOff = true);
    try {
      // Fetch the focused month plus a month of padding on each side so the
      // adjacent-month days in the grid (and a quick swipe) already have data.
      final start = DateTime(month.year, month.month - 1, 1);
      final end = DateTime(month.year, month.month + 2, 0);
      final data = await _dataService.getTeamTimeOff(start: start, end: end);
      if (mounted) {
        setState(() {
          _teamOff = data;
          _loadingTeamOff = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingTeamOff = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load team calendar: $e')),
        );
      }
    }
  }

  List<String> _getOffForDay(DateTime day) {
    return _teamOff[DateTime(day.year, day.month, day.day)] ?? const [];
  }

  Widget _buildTeamCalendarTab() {
    final selectedOff = _selectedDay == null ? const <String>[] : _getOffForDay(_selectedDay!);

    return Column(
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: TableCalendar<String>(
              firstDay: DateTime.utc(2020, 1, 1),
              lastDay: DateTime.utc(2030, 12, 31),
              focusedDay: _focusedDay,
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
              startingDayOfWeek: StartingDayOfWeek.monday,
              calendarFormat: CalendarFormat.month,
              availableCalendarFormats: const {CalendarFormat.month: 'Month'},
              eventLoader: _getOffForDay,
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                });
              },
              onPageChanged: (focusedDay) {
                _focusedDay = focusedDay;
                _loadTeamOff(focusedDay, showSpinner: false);
              },
              calendarStyle: CalendarStyle(
                outsideDaysVisible: false,
                todayDecoration: BoxDecoration(
                  color: AppColors.primaryLight.withAlpha(120),
                  shape: BoxShape.circle,
                ),
                selectedDecoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
              ),
              calendarBuilders: CalendarBuilders(
                markerBuilder: (context, day, events) {
                  if (events.isEmpty) return null;
                  return Positioned(
                    bottom: 1,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      decoration: const BoxDecoration(
                        color: AppColors.error,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${events.length}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Number of staff on approved time off',
                  style: TextStyle(fontSize: 12, color: AppColors.grey600),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 16),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _loadTeamOff(_focusedDay),
            child: _buildSelectedDayOffPanel(selectedOff),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedDayOffPanel(List<String> names) {
    final dateStr = _selectedDay == null ? '' : ukDateWithDay(_selectedDay!);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Text(dateStr, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 12),
        if (_loadingTeamOff && _teamOff.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (names.isEmpty)
          Row(
            children: [
              Picon(PiconsFill.checkCircle, color: AppColors.success, size: 20),
              const SizedBox(width: 8),
              const Text('All staff available', style: TextStyle(color: AppColors.grey600, fontSize: 14)),
            ],
          )
        else ...[
          Text(
            '${names.length} ${names.length == 1 ? 'person' : 'people'} off',
            style: const TextStyle(color: AppColors.error, fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: names
                .map((n) => Chip(
                      avatar: Picon(PiconsDuotone.user, size: 16, color: AppColors.warning),
                      label: Text(n, style: const TextStyle(fontSize: 13)),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ))
                .toList(),
          ),
        ],
      ],
    );
  }

  // ── Team Coverage Tab ───────────────────────────────────────────────

  Widget _buildCoverageTab() {
    if (_loadingCoverage) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _loadCoverage,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 5,
        itemBuilder: (context, index) {
          final dayKey = '${index + 1}';
          final dayData = _coverage[dayKey] as Map<String, dynamic>?;
          if (dayData == null) return const SizedBox.shrink();

          final dayName = dayData['day_name'] as String? ?? _dayNames[index + 1]!;
          final available = (dayData['available'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final unavailable = (dayData['unavailable'] as List?)?.cast<Map<String, dynamic>>() ?? [];

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(dayName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: available.isEmpty ? AppColors.error.withAlpha(30) : AppColors.success.withAlpha(30),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${available.length} available',
                          style: TextStyle(
                            fontSize: 12,
                            color: available.isEmpty ? AppColors.error : AppColors.success,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (available.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: available.map((s) => Chip(
                        avatar: Picon(PiconsFill.checkCircle, size: 16, color: AppColors.success),
                        label: Text(s['name'] as String, style: const TextStyle(fontSize: 13)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )).toList(),
                    ),
                  ],
                  if (unavailable.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: unavailable.map((s) => Chip(
                        avatar: Picon(PiconsFill.xCircle, size: 16, color: AppColors.error),
                        label: Text(s['name'] as String, style: TextStyle(fontSize: 13, color: AppColors.grey600)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )).toList(),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
