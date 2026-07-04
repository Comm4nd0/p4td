import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:table_calendar/table_calendar.dart';
import '../constants/app_colors.dart';
import '../models/boarding_request.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/assignment_action_dialogs.dart';
import '../widgets/boarding_request_card.dart';
import '../widgets/skeleton_loaders.dart';
import 'request_boarding_screen.dart';

/// Boarding requests screen with List and Calendar tabs.
///
/// For owners this shows their own requests (edit/cancel while pending).
/// For staff with the manage-boarding permission it's the full Manage
/// Boarding section: approve/deny/set pending, edit dates, delete, and a
/// working calendar — tap a day to see its stays, tap a stay to act on it.
/// Staff without the permission get a read-only view.
class BoardingRequestListScreen extends StatefulWidget {
  final bool isStaff;
  final bool canManageBoarding;

  const BoardingRequestListScreen({
    super.key,
    this.isStaff = false,
    this.canManageBoarding = false,
  });

  @override
  State<BoardingRequestListScreen> createState() => _BoardingRequestListScreenState();
}

class _BoardingRequestListScreenState extends State<BoardingRequestListScreen> {
  final DataService _dataService = getIt<DataService>();

  List<BoardingRequest> _requests = [];
  bool _loading = true;
  String? _error;
  String _filter = 'ALL'; // ALL, PENDING, APPROVED, DENIED

  // Calendar state
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, List<BoardingRequest>> _events = {};

  bool get _canManage => widget.isStaff && widget.canManageBoarding;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    setState(() {
      _loading = _requests.isEmpty;
      _error = null;
    });
    try {
      final requests = await _dataService.getBoardingRequests();
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _processEvents(requests);
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

  void _processEvents(List<BoardingRequest> requests) {
    _events = {};
    for (var request in requests) {
      // Denied requests aren't stays, so keep them off the calendar (they
      // remain visible in the list tab).
      if (request.status == BoardingRequestStatus.denied) continue;

      for (var day = request.startDate;
          !day.isAfter(request.endDate);
          day = day.add(const Duration(days: 1))) {
        final dateKey = DateTime(day.year, day.month, day.day);
        (_events[dateKey] ??= []).add(request);
      }
    }
  }

  List<BoardingRequest> _getEventsForDay(DateTime day) {
    return _events[DateTime(day.year, day.month, day.day)] ?? [];
  }

  List<BoardingRequest> get _filteredRequests {
    if (_filter == 'ALL') return _requests;
    final status = BoardingRequestStatus.values.firstWhere(
      (s) => s.name.toUpperCase() == _filter,
      orElse: () => BoardingRequestStatus.pending,
    );
    return _requests.where((r) => r.status == status).toList();
  }

  // --- actions -------------------------------------------------------------

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.success),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  Future<void> _updateStatus(BoardingRequest request, String newStatus) async {
    try {
      await _dataService.updateBoardingRequestStatus(request.id, newStatus);
      _showSuccess('Request ${newStatus.toLowerCase()}');
      await _loadRequests();
    } catch (e) {
      _showError('Failed to update: $e');
    }
  }

  /// Approve a boarding request, first letting the approver pick which staff
  /// member the dog boards with.
  Future<void> _approve(BoardingRequest request) async {
    final staffId = await pickStaffMember(
      context,
      title: 'Approve & assign carer',
      subtitle: 'Who is ${request.dogNames.join(", ")} boarding with?',
      confirmLabel: 'Approve',
      initialStaffMembers: const [],
      initialAvailableStaffIds: const {},
      loadStaff: () => _dataService.getStaffMembers(),
      loadAvailableIds: () => _dataService.getAvailableStaffForDate(request.startDate),
    );
    if (staffId == null) return; // cancelled
    try {
      await _dataService.updateBoardingRequestStatus(request.id, 'APPROVED', assignedStaffId: staffId);
      _showSuccess('Request approved');
      await _loadRequests();
    } catch (e) {
      _showError('Failed to update: $e');
    }
  }

  /// Permanently delete a boarding booking (e.g. an accidental duplicate),
  /// after confirmation. Unlike Deny, this removes it from history entirely.
  Future<void> _delete(BoardingRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete booking?'),
        content: Text(
          'Permanently delete the boarding booking for '
          '${request.dogNames.join(", ")} '
          '(${ukDate(request.startDate)} - ${ukDate(request.endDate)})?\n\n'
          'Use this to remove duplicates or mistakes. To turn down a request, '
          'use Deny instead so the owner can see the outcome.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _dataService.deleteBoardingRequest(request.id);
      _showSuccess('Booking deleted');
      await _loadRequests();
    } catch (e) {
      _showError('Failed to delete: $e');
    }
  }

  /// Owner withdrawing their own pending request.
  Future<void> _cancelOwn(BoardingRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel request?'),
        content: Text(
          'Cancel the boarding request for ${request.dogNames.join(", ")} '
          '(${ukDate(request.startDate)} - ${ukDate(request.endDate)})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep request'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Cancel request'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _dataService.deleteBoardingRequest(request.id);
      _showSuccess('Request cancelled');
      await _loadRequests();
    } catch (e) {
      _showError('Failed to cancel: $e');
    }
  }

  Future<void> _edit(BoardingRequest request) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => RequestBoardingScreen(existing: request)),
    );
    if (changed == true) await _loadRequests();
  }

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final pendingCount = _requests.where((r) => r.status == BoardingRequestStatus.pending).length;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_canManage ? 'Manage Boarding' : 'My Boarding Requests'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: Picon(PiconsDuotone.arrowClockwise),
              onPressed: _loadRequests,
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Picon(PiconsDuotone.listDashes, size: 20),
                    const SizedBox(width: 6),
                    const Text('List'),
                    if (pendingCount > 0) ...[
                      const SizedBox(width: 6),
                      _buildCountBadge(pendingCount),
                    ],
                  ],
                ),
              ),
              const Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Picon(PiconsDuotone.calendar, size: 20),
                    SizedBox(width: 6),
                    Text('Calendar'),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: _loading
            ? const ListTileSkeletonList()
            : _error != null
                ? _buildErrorState()
                : TabBarView(
                    children: [
                      _buildListTab(),
                      _buildCalendarTab(),
                    ],
                  ),
      ),
    );
  }

  Widget _buildCountBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildErrorState() {
    return RefreshIndicator.adaptive(
      onRefresh: _loadRequests,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: Center(child: Text('Error: $_error')),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return RefreshIndicator.adaptive(
      onRefresh: _loadRequests,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.4,
            child: Center(
              child: Text(message, style: TextStyle(color: Colors.grey[600])),
            ),
          ),
        ],
      ),
    );
  }

  // --- list tab ------------------------------------------------------------

  Widget _buildListTab() {
    final filtered = _filteredRequests;

    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              _buildFilterChip('ALL', 'All'),
              const SizedBox(width: 8),
              _buildFilterChip('PENDING', 'Pending'),
              const SizedBox(width: 8),
              _buildFilterChip('APPROVED', 'Approved'),
              const SizedBox(width: 8),
              _buildFilterChip('DENIED', 'Denied'),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(_filter == 'ALL'
                  ? 'No boarding requests found'
                  : 'No ${_filter.toLowerCase()} requests')
              : RefreshIndicator.adaptive(
                  onRefresh: _loadRequests,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) => _buildRequestCard(filtered[index]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(String value, String label) {
    return FilterChip(
      label: Text(label),
      selected: _filter == value,
      onSelected: (selected) {
        setState(() => _filter = value);
      },
    );
  }

  Widget _buildRequestCard(BoardingRequest request) {
    return BoardingRequestCard(
      request: request,
      showOwner: widget.isStaff,
      canManage: _canManage,
      onApprove: _canManage ? () => _approve(request) : null,
      onDeny: _canManage ? () => _updateStatus(request, 'DENIED') : null,
      onSetPending: _canManage ? () => _updateStatus(request, 'PENDING') : null,
      onDelete: _canManage ? () => _delete(request) : null,
      // Owners can amend/withdraw their own request while it's pending.
      onEdit: (_canManage || !widget.isStaff) ? () => _edit(request) : null,
      onCancel: !widget.isStaff ? () => _cancelOwn(request) : null,
    );
  }

  // --- calendar tab ----------------------------------------------------------

  Widget _buildCalendarTab() {
    final selectedEvents = _selectedDay == null ? <BoardingRequest>[] : _getEventsForDay(_selectedDay!);

    return Column(
      children: [
        TableCalendar<BoardingRequest>(
          firstDay: DateTime.utc(2020, 10, 16),
          lastDay: DateTime.utc(2030, 3, 14),
          focusedDay: _focusedDay,
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          onDaySelected: (selectedDay, focusedDay) {
            setState(() {
              _selectedDay = selectedDay;
              _focusedDay = focusedDay;
            });
          },
          eventLoader: _getEventsForDay,
          calendarFormat: CalendarFormat.month,
          startingDayOfWeek: StartingDayOfWeek.monday,
          calendarStyle: const CalendarStyle(
            markerSize: 7,
          ),
          calendarBuilders: CalendarBuilders(
            markerBuilder: (context, day, events) {
              if (events.isEmpty) return null;

              // One dot per status present that day, so a day with both an
              // approved stay and a pending request shows green + orange.
              final statuses = <BoardingRequestStatus>{for (final e in events) e.status};
              final dots = [
                if (statuses.contains(BoardingRequestStatus.approved)) Colors.green,
                if (statuses.contains(BoardingRequestStatus.pending)) Colors.orange,
              ];
              if (dots.isEmpty) return null;

              return Positioned(
                bottom: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final color in dots)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                        width: 7.0,
                        height: 7.0,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        if (_selectedDay != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    ukDateWithDay(_selectedDay!),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                Text(
                  selectedEvents.isEmpty
                      ? 'No dogs boarding'
                      : '${selectedEvents.length} booking${selectedEvents.length == 1 ? '' : 's'}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
        Expanded(
          child: selectedEvents.isEmpty
              ? Center(
                  child: Text(
                    'No bookings for this day',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: selectedEvents.length,
                  itemBuilder: (context, index) => _buildDayEventTile(selectedEvents[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildDayEventTile(BoardingRequest request) {
    final color = BoardingStatusBadge.colorFor(request.status);
    final nights = request.endDate.difference(request.startDate).inDays;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: Picon(PiconsDuotone.bed, color: color),
        title: Text(
          request.dogNames.join(', '),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.isStaff) Text('Owner: ${request.ownerName}'),
            Text('${ukDate(request.startDate)} - ${ukDate(request.endDate)} · $nights night${nights == 1 ? '' : 's'}'),
            if (request.assignedStaffName != null) Text('Boarding with ${request.assignedStaffName}'),
          ],
        ),
        trailing: BoardingStatusBadge(status: request.status),
        isThreeLine: widget.isStaff || request.assignedStaffName != null,
        onTap: () => _showRequestSheet(request),
      ),
    );
  }

  /// Bottom sheet with the full request card and its actions, opened from a
  /// calendar day tile. Actions close the sheet first, then run as usual.
  void _showRequestSheet(BoardingRequest request) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        void closeThen(Future<void> Function() action) {
          Navigator.pop(sheetContext);
          action();
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: BoardingRequestCard(
              request: request,
              showOwner: widget.isStaff,
              canManage: _canManage,
              onApprove: _canManage ? () => closeThen(() => _approve(request)) : null,
              onDeny: _canManage ? () => closeThen(() => _updateStatus(request, 'DENIED')) : null,
              onSetPending: _canManage ? () => closeThen(() => _updateStatus(request, 'PENDING')) : null,
              onDelete: _canManage ? () => closeThen(() => _delete(request)) : null,
              onEdit: (_canManage || !widget.isStaff) ? () => closeThen(() => _edit(request)) : null,
              onCancel: !widget.isStaff ? () => closeThen(() => _cancelOwn(request)) : null,
            ),
          ),
        );
      },
    );
  }
}
