import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../utils/date_formats.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/request_timeline.dart';
import '../widgets/skeleton_loaders.dart';
import '../widgets/assignment_action_dialogs.dart';
import '../widgets/boarding_request_card.dart';
import 'request_boarding_screen.dart';

class StaffNotificationsScreen extends StatefulWidget {
  final bool canManageRequests;

  const StaffNotificationsScreen({super.key, this.canManageRequests = false});

  @override
  State<StaffNotificationsScreen> createState() => _StaffNotificationsScreenState();
}

class _StaffNotificationsScreenState extends State<StaffNotificationsScreen> {
  final DataService _dataService = getIt<DataService>();
  List<DateChangeRequest> _dateRequests = [];
  List<BoardingRequest> _boardingRequests = [];
  bool _loading = true;
  String _filter = 'PENDING'; // PENDING, ALL, APPROVED, DENIED

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    setState(() => _loading = true);
    try {
      final dateRequests = await _dataService.getDateChangeRequests();
      final boardingRequests = await _dataService.getBoardingRequests();
      
      if (mounted) {
        setState(() {
          _dateRequests = dateRequests;
          _boardingRequests = boardingRequests;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load requests: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  List<T> _filterList<T>(List<T> list, dynamic Function(T) getStatus) {
    if (_filter == 'ALL') return list;
    return list.where((item) {
      final status = getStatus(item);
      final statusStr = status.toString().toUpperCase();
      switch (_filter) {
        case 'PENDING':
          return statusStr.contains('PENDING');
        case 'APPROVED':
          return statusStr.contains('APPROVED');
        case 'DENIED':
          return statusStr.contains('DENIED');
        default:
          return true;
      }
    }).toList();
  }

  Future<void> _updateDateStatus(DateChangeRequest request, String newStatus) async {
    try {
      await _dataService.updateDateChangeRequestStatus(request.id, newStatus);
      _showSuccess('Request ${newStatus.toLowerCase()}');
      _loadRequests();
    } catch (e) {
      _showError('Failed to update: $e');
    }
  }

  Future<void> _updateBoardingStatus(BoardingRequest request, String newStatus) async {
    try {
      await _dataService.updateBoardingRequestStatus(request.id, newStatus);
      _showSuccess('Request ${newStatus.toLowerCase()}');
      _loadRequests();
    } catch (e) {
      _showError('Failed to update: $e');
    }
  }

  /// Permanently delete a boarding booking (e.g. an accidental duplicate),
  /// after confirmation. Unlike Deny, this removes it from history entirely.
  Future<void> _deleteBoarding(BoardingRequest request) async {
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
      _loadRequests();
    } catch (e) {
      _showError('Failed to delete: $e');
    }
  }

  /// Approve a boarding request, first letting the approver pick which staff
  /// member the dog boards with.
  Future<void> _approveBoarding(BoardingRequest request) async {
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
      _loadRequests();
    } catch (e) {
      _showError('Failed to update: $e');
    }
  }

  /// Edit the dates/instructions of a booking (any status — staff only).
  Future<void> _editBoarding(BoardingRequest request) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => RequestBoardingScreen(existing: request)),
    );
    if (changed == true) _loadRequests();
  }

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

  @override
  Widget build(BuildContext context) {
    final pendingDateCount = _dateRequests.where((r) => r.status == RequestStatus.pending).length;
    final pendingBoardingCount = _boardingRequests.where((r) => r.status == BoardingRequestStatus.pending).length;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Staff Dashboard'),
          bottom: TabBar(
            tabs: [
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Date Changes'),
                    if (pendingDateCount > 0) ...[
                      const SizedBox(width: 8),
                      _buildCountBadge(pendingDateCount),
                    ],
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Boarding'),
                    if (pendingBoardingCount > 0) ...[
                      const SizedBox(width: 8),
                      _buildCountBadge(pendingBoardingCount),
                    ],
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: Picon(PiconsDuotone.arrowClockwise),
              onPressed: _loadRequests,
            ),
          ],
        ),
        body: Column(
          children: [
            // Filter chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  _buildFilterChip('PENDING', 'Pending'),
                  const SizedBox(width: 8),
                  _buildFilterChip('APPROVED', 'Approved'),
                  const SizedBox(width: 8),
                  _buildFilterChip('DENIED', 'Denied'),
                  const SizedBox(width: 8),
                  _buildFilterChip('ALL', 'All'),
                ],
              ),
            ),
            // Content
            Expanded(
              child: _loading
                  ? const ListTileSkeletonList()
                  : TabBarView(
                      children: [
                        _buildDateChangeList(),
                        _buildBoardingList(),
                      ],
                    ),
            ),
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

  Widget _buildFilterChip(String value, String label) {
    final isSelected = _filter == value;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() => _filter = value);
      },
    );
  }

  Widget _buildDateChangeList() {
    final filtered = _filterList(_dateRequests, (r) => r.status);
    
    if (filtered.isEmpty) return _buildEmptyState();

    return RefreshIndicator.adaptive(
      onRefresh: _loadRequests,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: filtered.length,
        itemBuilder: (context, index) => _buildDateRequestCard(filtered[index]),
      ),
    );
  }

  Widget _buildBoardingList() {
    final filtered = _filterList(_boardingRequests, (r) => r.status);

    if (filtered.isEmpty) return _buildEmptyState();

    return RefreshIndicator.adaptive(
      onRefresh: _loadRequests,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: filtered.length,
        itemBuilder: (context, index) => _buildBoardingRequestCard(filtered[index]),
      ),
    );
  }

  Widget _buildEmptyState() {
    return RefreshIndicator.adaptive(
      onRefresh: _loadRequests,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: Center(
              child: Text(
                _filter == 'PENDING' ? 'No pending requests' : 'No requests found',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateRequestCard(DateChangeRequest request) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Picon(PiconsDuotone.pawPrint, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.dogName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        'Owner: ${request.ownerName}',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _buildStatusBadge(request.status.toString().split('.').last),
                    if (request.status != RequestStatus.pending && request.approvedByName != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          'by ${request.approvedByName}',
                          style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const Divider(height: 24),
            // Details
            Row(
              children: [
                Picon(
                  request.requestType == RequestType.cancel
                      ? PiconsDuotone.xCircle
                      : request.requestType == RequestType.addDay
                          ? PiconsDuotone.plusCircle
                          : PiconsDuotone.arrowsLeftRight,
                  color: request.requestType == RequestType.cancel
                      ? Colors.red
                      : request.requestType == RequestType.addDay
                          ? Colors.green
                          : AppColors.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  request.requestTypeDisplayName,
                  style: TextStyle(
                    color: request.requestType == RequestType.cancel
                        ? Colors.red
                        : request.requestType == RequestType.addDay
                            ? Colors.green
                            : AppColors.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (request.requestType == RequestType.cancel)
              Text(
                'Cancel: ${ukDateWithDay(request.originalDate!)}',
                style: const TextStyle(fontSize: 14),
              )
            else if (request.requestType == RequestType.addDay)
              Text(
                'Additional day: ${ukDateWithDay(request.newDate!)}',
                style: const TextStyle(fontSize: 14),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('From:', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                        Text(ukDateWithDay(request.originalDate!)),
                      ],
                    ),
                  ),
                  Picon(PiconsDuotone.arrowRight, size: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('To:', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                        Text(ukDateWithDay(request.newDate!)),
                      ],
                    ),
                  ),
                ],
              ),
             if (request.isCharged) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Picon(PiconsDuotone.currencyDollar, color: Colors.orange[800], size: 16),
                    const SizedBox(width: 4),
                    Text(
                      'Customer will be charged',
                      style: TextStyle(color: Colors.orange[800], fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            RequestTimeline(
              status: request.status.toString().split('.').last,
              createdAt: request.createdAt,
              resolvedBy: request.approvedByName,
            ),
            // Actions
            if (widget.canManageRequests) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (request.status != RequestStatus.pending)
                    TextButton(
                      onPressed: () => _updateDateStatus(request, 'PENDING'),
                      child: const Text('Set Pending'),
                    ),
                  if (request.status != RequestStatus.denied)
                    OutlinedButton(
                      onPressed: () => _updateDateStatus(request, 'DENIED'),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Deny'),
                    ),
                  const SizedBox(width: 8),
                  if (request.status != RequestStatus.approved)
                    FilledButton(
                      onPressed: () => _updateDateStatus(request, 'APPROVED'),
                      child: const Text('Approve'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBoardingRequestCard(BoardingRequest request) {
    final canManage = widget.canManageRequests;
    return BoardingRequestCard(
      request: request,
      showOwner: true,
      canManage: canManage,
      onApprove: canManage ? () => _approveBoarding(request) : null,
      onDeny: canManage ? () => _updateBoardingStatus(request, 'DENIED') : null,
      onSetPending: canManage ? () => _updateBoardingStatus(request, 'PENDING') : null,
      onDelete: canManage ? () => _deleteBoarding(request) : null,
      onEdit: canManage ? () => _editBoarding(request) : null,
    );
  }

  Widget _buildStatusBadge(String statusStr) {
    Color color;
    String label = statusStr.toUpperCase();
    
    if (label.contains('PENDING')) {
      color = Colors.orange;
      label = 'Pending';
    } else if (label.contains('APPROVED')) {
      color = Colors.green;
      label = 'Approved';
    } else if (label.contains('DENIED')) {
      color = Colors.red;
      label = 'Denied';
    } else {
      color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}
