import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../models/dog.dart';
import '../models/date_change_request.dart';
import '../models/owner_profile.dart';
import '../services/data_service.dart';
import 'gallery_screen.dart';
import 'edit_dog_screen.dart';
import 'owner_details_dialog.dart';
import 'query_list_screen.dart';
import 'query_detail_screen.dart';

class DogHomeScreen extends StatefulWidget {
  final Dog dog;
  final bool isStaff;

  const DogHomeScreen({super.key, required this.dog, this.isStaff = false});

  @override
  State<DogHomeScreen> createState() => _DogHomeScreenState();
}

class _DogHomeScreenState extends State<DogHomeScreen> {
  late Dog _dog;
  final _dataService = ApiDataService();
  List<DateChangeRequest> _requests = [];
  bool _loadingRequests = false;

  @override
  void initState() {
    super.initState();
    _dog = widget.dog;
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    setState(() => _loadingRequests = true);
    try {
      final requests = await _dataService.getDateChangeRequests(dogId: _dog.id);
      if (mounted) {
        setState(() {
          _requests = requests;
          _loadingRequests = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingRequests = false);
      }
    }
  }

  Future<void> _showOwnerDetails() async {
    if (_dog.ownerDetails == null) return;

    try {
      final profile = await _dataService.getOwnerProfile(_dog.ownerDetails!.userId);
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => OwnerDetailsDialog(
            ownerProfile: profile,
            ownerId: _dog.ownerDetails!.userId,
            isStaff: widget.isStaff,
            onUpdated: () {
              // Refresh if needed
            },
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load owner details: $e')),
        );
      }
    }
  }

  Future<void> _contactOwner() async {
    if (_dog.ownerDetails == null) return;

    try {
      final owner = OwnerProfile(
        userId: _dog.ownerDetails!.userId,
        username: _dog.ownerDetails!.username,
        email: _dog.ownerDetails!.email,
      );

      final subjectController = TextEditingController(text: 'Re: ${_dog.name}');
      final messageController = TextEditingController();
      final formKey = GlobalKey<FormState>();

      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Message ${owner.username}'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: subjectController,
                    decoration: const InputDecoration(
                      labelText: 'Subject',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: messageController,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      hintText: 'Your message to the owner',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 4,
                    validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(context, true);
                }
              },
              child: const Text('Send'),
            ),
          ],
        ),
      );

      if (result == true && mounted) {
        try {
          final query = await _dataService.createStaffQuery(
            ownerId: owner.userId,
            subject: subjectController.text.trim(),
            initialMessage: messageController.text.trim(),
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Message sent'), backgroundColor: Colors.green),
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => QueryDetailScreen(
                  queryId: query.id,
                  isStaff: true,
                  canReplyQueries: true,
                ),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to send message: $e')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to contact owner: $e')),
        );
      }
    }
  }

  List<DateTime> _getUpcomingDaycareDates() {
    final List<DateTime> dates = [];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final threeMonthsLater = DateTime(now.year, now.month + 3, now.day);

    final dayNumbers = _dog.daysInDaycare.map((d) => d.dayNumber).toSet();

    var current = today;
    while (current.isBefore(threeMonthsLater)) {
      if (dayNumbers.contains(current.weekday)) {
        dates.add(current);
      }
      current = current.add(const Duration(days: 1));
    }

    return dates;
  }

  bool _isConfirmed(DateTime date) {
    final now = DateTime.now();
    final oneMonthLater = DateTime(now.year, now.month + 1, now.day);
    return date.isBefore(oneMonthLater);
  }

  void _showDateChangeRequest(DateTime date) {
    final isConfirmed = _isConfirmed(date);
    final formattedDate = DateFormat('EEEE, d MMMM yyyy').format(date);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Date Change Request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Date: $formattedDate'),
            const SizedBox(height: 16),
            if (isConfirmed) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange[800]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This date is within 1 month. You will still be charged for this day.',
                        style: TextStyle(color: Colors.orange[800]),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            const Text('What would you like to do?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back'),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.pop(context);
              _showCancelConfirmation(date, isConfirmed);
            },
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Cancel Date'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _showDatePicker(date, isConfirmed);
            },
            child: const Text('Change Date'),
          ),
        ],
      ),
    );
  }

  void _showCancelConfirmation(DateTime originalDate, bool isConfirmed) {
    final formattedDate = DateFormat('EEEE, d MMMM yyyy').format(originalDate);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Cancellation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to cancel your daycare booking for $formattedDate?'),
            if (isConfirmed) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.red[800]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You will still be charged for this day.',
                        style: TextStyle(color: Colors.red[800], fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _submitDateChangeRequest(originalDate, null);
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Confirm Cancellation'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDatePicker(DateTime originalDate, bool isConfirmed) async {
    final now = DateTime.now();
    final newDate = await showDatePicker(
      context: context,
      initialDate: originalDate.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: DateTime(now.year, now.month + 3, now.day),
      helpText: 'Select new date',
    );

    if (newDate != null && mounted) {
      _showChangeConfirmation(originalDate, newDate, isConfirmed);
    }
  }

  void _showChangeConfirmation(DateTime originalDate, DateTime newDate, bool isConfirmed) {
    final formattedOriginal = DateFormat('EEE, d MMM').format(originalDate);
    final formattedNew = DateFormat('EEE, d MMM').format(newDate);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Date Change'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Text('From', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                      const SizedBox(height: 4),
                      Text(formattedOriginal, style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward),
                Expanded(
                  child: Column(
                    children: [
                      Text('To', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                      const SizedBox(height: 4),
                      Text(formattedNew, style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ),
            if (isConfirmed) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange[800]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'The original date is within 1 month. You will still be charged for that day.',
                        style: TextStyle(color: Colors.orange[800]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _submitDateChangeRequest(originalDate, newDate);
            },
            child: const Text('Confirm Change'),
          ),
        ],
      ),
    );
  }

  Future<void> _submitDateChangeRequest(DateTime originalDate, DateTime? newDate) async {
    try {
      await _dataService.submitDateChangeRequest(
        dogId: _dog.id,
        originalDate: originalDate,
        newDate: newDate,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(newDate == null
              ? 'Cancellation request submitted'
              : 'Date change request submitted'),
            backgroundColor: Colors.green,
          ),
        );
        _loadRequests(); // Refresh the requests list
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit request: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildRequestsSection() {
    if (_loadingRequests) {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_requests.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.only(top: 16),
      elevation: 0,
      color: Colors.white.withOpacity(0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ExpansionTile(
        title: Text(
          'Active Requests (${_requests.length})',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).primaryColor,
            fontSize: 14,
          ),
        ),
        initiallyExpanded: false,
        childrenPadding: const EdgeInsets.all(8),
        children: _requests.map((request) => Card(
          elevation: 1,
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            dense: true,
            leading: Icon(
              request.requestType == RequestType.cancel
                  ? Icons.cancel_outlined
                  : Icons.swap_horiz,
              color: request.requestType == RequestType.cancel
                  ? Colors.red
                  : Colors.blue,
            ),
            title: Text(
              request.requestType == RequestType.cancel
                  ? 'Cancel ${DateFormat('EEE, d MMM').format(request.originalDate)}'
                  : '${DateFormat('EEE, d MMM').format(request.originalDate)} → ${DateFormat('EEE, d MMM').format(request.newDate!)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            subtitle: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _getStatusColor(request.status).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    request.statusDisplayName,
                    style: TextStyle(
                      fontSize: 10,
                      color: _getStatusColor(request.status),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (request.isCharged) ...[
                  const SizedBox(width: 8),
                  Text(
                    '(charged)',
                    style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                  ),
                ],
              ],
            ),
          ),
        )).toList(),
      ),
    );
  }

  Color _getStatusColor(RequestStatus status) {
    switch (status) {
      case RequestStatus.pending:
        return Colors.orange;
      case RequestStatus.approved:
        return Colors.green;
      case RequestStatus.denied:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final upcomingDates = _getUpcomingDaycareDates();

    return Scaffold(
      appBar: AppBar(
        title: Text(_dog.name),
        actions: [
          if (widget.isStaff && _dog.ownerDetails != null)
            IconButton(
              icon: const Icon(Icons.message),
              tooltip: 'Contact Owner',
              onPressed: _contactOwner,
            ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final updatedDog = await Navigator.push<Dog>(
                context,
                MaterialPageRoute(
                  builder: (_) => EditDogScreen(dog: _dog),
                ),
              );
              if (updatedDog != null) {
                setState(() {
                  _dog = updatedDog;
                });
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: Theme.of(context).primaryColor.withOpacity(0.1),
              child: Column(
                children: [
                  Row(
                    children: [
                      Hero(
                        tag: 'dog_image_${_dog.id}',
                        child: CircleAvatar(
                          radius: 40,
                          backgroundImage: _dog.profileImageUrl != null 
                              ? CachedNetworkImageProvider(_dog.profileImageUrl!) 
                              : null,
                          child: _dog.profileImageUrl == null 
                              ? const Icon(Icons.pets, size: 40) 
                              : null,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _dog.name,
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            if (widget.isStaff && _dog.ownerDetails != null)
                              TextButton.icon(
                                onPressed: _showOwnerDetails,
                                icon: const Icon(Icons.person, size: 18),
                                label: const Text('Owner Info'),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_dog.daysInDaycare.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Upcoming Dates',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Colors.grey[700],
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 80,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: upcomingDates.length,
                            itemBuilder: (context, index) {
                              final date = upcomingDates[index];
                              final isConfirmed = _isConfirmed(date);
                              return GestureDetector(
                                onTap: () => _showDateChangeRequest(date),
                                child: Container(
                                  width: 60,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: isConfirmed ? Colors.green[100] : Colors.grey[200],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isConfirmed ? Colors.green : Colors.grey[400]!,
                                      width: 1,
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        DateFormat('E').format(date),
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isConfirmed ? Colors.green[800] : Colors.grey[600],
                                        ),
                                      ),
                                      Text(
                                        DateFormat('d').format(date),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: isConfirmed ? Colors.green[800] : Colors.grey[600],
                                        ),
                                      ),
                                      Text(
                                        DateFormat('MMM').format(date),
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isConfirmed ? Colors.green[700] : Colors.grey[500],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                  _buildRequestsSection(),
                ],
              ),
            ),
            // Embedded Gallery
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: GalleryScreen(
                dogId: _dog.id, 
                isStaff: widget.isStaff, 
                embed: true, // IMPORTANT: Enable embedding mode
              ),
            ),
            const SizedBox(height: 80), // Extra space at bottom for scrolling nicely
          ],
        ),
      ),
    );
  }
}
