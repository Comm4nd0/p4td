import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../services/data_service.dart';

class StaffNotificationsScreen extends StatefulWidget {
  const StaffNotificationsScreen({super.key});

  @override
  State<StaffNotificationsScreen> createState() => _StaffNotificationsScreenState();
}

class _StaffNotificationsScreenState extends State<StaffNotificationsScreen> {
  final _dataService = ApiDataService();
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
          SnackBar(content: Text('Failed to load requests: $e'), backgroundColor: Colors.red),
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

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
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
              icon: const Icon(Icons.refresh),
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
                  ? const Center(child: CircularProgressIndicator())
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

    return RefreshIndicator(
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

    return RefreshIndicator(
      onRefresh: _loadRequests,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: filtered.length,
        itemBuilder: (context, index) => _buildBoardingRequestCard(filtered[index]),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Text(
        _filter == 'PENDING' ? 'No pending requests' : 'No requests found',
        style: TextStyle(color: Colors.grey[600]),
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
                const Icon(Icons.pets, size: 20),
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
                Icon(
                  request.requestType == RequestType.cancel ? Icons.cancel_outlined : Icons.swap_horiz,
                  color: request.requestType == RequestType.cancel ? Colors.red : Colors.blue,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  request.requestType == RequestType.cancel ? 'Cancellation' : 'Date Change',
                  style: TextStyle(
                    color: request.requestType == RequestType.cancel ? Colors.red : Colors.blue,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (request.requestType == RequestType.cancel)
              Text(
                'Cancel: ${DateFormat('EEE, d MMM yyyy').format(request.originalDate)}',
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
                        Text(DateFormat('EEE, d MMM').format(request.originalDate)),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward, size: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('To:', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                        Text(DateFormat('EEE, d MMM').format(request.newDate!)),
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
                    Icon(Icons.attach_money, color: Colors.orange[800], size: 16),
                    const SizedBox(width: 4),
                    Text(
                      'Customer will be charged',
                      style: TextStyle(color: Colors.orange[800], fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Requested: ${DateFormat('d MMM yyyy, HH:mm').format(request.createdAt)}',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
            // Actions
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
        ),
      ),
    );
  }

  Widget _buildBoardingRequestCard(BoardingRequest request) {
    final isPending = request.status == BoardingRequestStatus.pending;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      // Highlight pending requests with a colored border
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isPending ? BorderSide(color: Colors.orange.shade300, width: 2) : BorderSide.none,
      ),
      elevation: isPending ? 4 : 1,
      surfaceTintColor: isPending ? Colors.orange.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.night_shelter, size: 20, color: Colors.purple.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.dogNames.join(', '),
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
                    if (request.status != BoardingRequestStatus.pending && request.approvedByName != null)
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
            // Dates
            Row(
              children: [
                const Icon(Icons.date_range, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${DateFormat('EEE, d MMM').format(request.startDate)} - ${DateFormat('EEE, d MMM yyyy').format(request.endDate)}',
                        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
                      ),
                      Text(
                        '${request.endDate.difference(request.startDate).inDays} nights',
                         style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (request.specialInstructions != null && request.specialInstructions!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Instructions:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                    Text(request.specialInstructions!, style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
               'Requested: ${DateFormat('d MMM, HH:mm').format(request.createdAt)}',
               style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
            // Actions
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                 if (request.status != BoardingRequestStatus.pending)
                  TextButton(
                    onPressed: () => _updateBoardingStatus(request, 'PENDING'),
                    child: const Text('Set Pending'),
                  ),
                if (request.status != BoardingRequestStatus.denied)
                  OutlinedButton(
                    onPressed: () => _updateBoardingStatus(request, 'DENIED'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                    child: const Text('Deny'),
                  ),
                const SizedBox(width: 8),
                if (request.status != BoardingRequestStatus.approved)
                  FilledButton(
                    onPressed: () => _updateBoardingStatus(request, 'APPROVED'),
                    child: const Text('Approve'),
                  ),
              ],
            ),
          ],
        ),
      ),
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
