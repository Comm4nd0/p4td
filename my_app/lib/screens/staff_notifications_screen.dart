import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/date_change_request.dart';
import '../services/data_service.dart';

class StaffNotificationsScreen extends StatefulWidget {
  const StaffNotificationsScreen({super.key});

  @override
  State<StaffNotificationsScreen> createState() => _StaffNotificationsScreenState();
}

class _StaffNotificationsScreenState extends State<StaffNotificationsScreen> {
  final _dataService = ApiDataService();
  List<DateChangeRequest> _requests = [];
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
      final requests = await _dataService.getDateChangeRequests();
      if (mounted) {
        setState(() {
          _requests = requests;
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

  List<DateChangeRequest> get _filteredRequests {
    if (_filter == 'ALL') return _requests;
    return _requests.where((r) {
      switch (_filter) {
        case 'PENDING':
          return r.status == RequestStatus.pending;
        case 'APPROVED':
          return r.status == RequestStatus.approved;
        case 'DENIED':
          return r.status == RequestStatus.denied;
        default:
          return true;
      }
    }).toList();
  }

  Future<void> _updateStatus(DateChangeRequest request, String newStatus) async {
    try {
      await _dataService.updateDateChangeRequestStatus(request.id, newStatus);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Request ${newStatus.toLowerCase()}'),
          backgroundColor: Colors.green,
        ),
      );
      _loadRequests();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = _requests.where((r) => r.status == RequestStatus.pending).length;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Date Change Requests'),
            if (pendingCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$pendingCount',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
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
          // Request list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filteredRequests.isEmpty
                    ? Center(
                        child: Text(
                          _filter == 'PENDING'
                              ? 'No pending requests'
                              : 'No requests found',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadRequests,
                        child: ListView.builder(
                          itemCount: _filteredRequests.length,
                          itemBuilder: (context, index) {
                            final request = _filteredRequests[index];
                            return _buildRequestCard(request);
                          },
                        ),
                      ),
          ),
        ],
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

  Widget _buildRequestCard(DateChangeRequest request) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with dog name and owner
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
                _buildStatusBadge(request.status),
              ],
            ),
            const Divider(height: 24),
            // Request details
            Row(
              children: [
                Icon(
                  request.requestType == RequestType.cancel
                      ? Icons.cancel_outlined
                      : Icons.swap_horiz,
                  color: request.requestType == RequestType.cancel
                      ? Colors.red
                      : Colors.blue,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  request.requestType == RequestType.cancel
                      ? 'Cancellation'
                      : 'Date Change',
                  style: TextStyle(
                    color: request.requestType == RequestType.cancel
                        ? Colors.red
                        : Colors.blue,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Date info
            if (request.requestType == RequestType.cancel)
              Text(
                'Cancel: ${DateFormat('EEEE, d MMMM yyyy').format(request.originalDate)}',
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
            // Charged warning
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
            // Requested date
            const SizedBox(height: 8),
            Text(
              'Requested: ${DateFormat('d MMM yyyy, HH:mm').format(request.createdAt)}',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
            // Action buttons
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (request.status != RequestStatus.pending)
                  TextButton(
                    onPressed: () => _updateStatus(request, 'PENDING'),
                    child: const Text('Set Pending'),
                  ),
                if (request.status != RequestStatus.denied)
                  OutlinedButton(
                    onPressed: () => _updateStatus(request, 'DENIED'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                    child: const Text('Deny'),
                  ),
                const SizedBox(width: 8),
                if (request.status != RequestStatus.approved)
                  FilledButton(
                    onPressed: () => _updateStatus(request, 'APPROVED'),
                    child: const Text('Approve'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(RequestStatus status) {
    Color color;
    String label;
    switch (status) {
      case RequestStatus.pending:
        color = Colors.orange;
        label = 'Pending';
        break;
      case RequestStatus.approved:
        color = Colors.green;
        label = 'Approved';
        break;
      case RequestStatus.denied:
        color = Colors.red;
        label = 'Denied';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}
