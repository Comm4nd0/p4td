import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import '../models/dog.dart';
import '../models/date_change_request.dart';
import '../models/boarding_request.dart';
import '../models/owner_profile.dart';
import '../services/data_service.dart';
import '../utils/date_formats.dart';
import 'gallery_screen.dart';
import 'edit_dog_screen.dart';
import 'owner_details_dialog.dart';
import 'query_detail_screen.dart';
import 'dog_notes_screen.dart';
import '../constants/app_colors.dart';

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
  List<BoardingRequest> _boardingRequests = [];
  bool _loadingBoardingRequests = false;

  @override
  void initState() {
    super.initState();
    _dog = widget.dog;
    _loadRequests();
    if (widget.isStaff) {
      _loadBoardingRequests();
    }
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

    final allOwners = _dog.allOwners;

    if (allOwners.length <= 1) {
      // Single owner - show details directly
      await _showOwnerDetailsFor(_dog.ownerDetails!.userId);
    } else {
      // Multiple owners - show picker
      if (!mounted) return;
      final selectedId = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Select Owner'),
          children: allOwners.map((owner) => SimpleDialogOption(
            onPressed: () => Navigator.pop(context, owner.userId),
            child: ListTile(
              leading: Picon(PiconsDuotone.user),
              title: Text(owner.username),
              subtitle: Text(owner.email),
              dense: true,
            ),
          )).toList(),
        ),
      );
      if (selectedId != null && mounted) {
        await _showOwnerDetailsFor(selectedId);
      }
    }
  }

  Future<void> _showOwnerDetailsFor(int ownerId) async {
    try {
      final profile = await _dataService.getOwnerProfile(ownerId);
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => OwnerDetailsDialog(
            ownerProfile: profile,
            ownerId: ownerId,
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

    final allOwners = _dog.allOwners;
    OwnerDetails selectedOwnerDetails;

    if (allOwners.length > 1) {
      // Multiple owners - let staff choose
      final selected = await showDialog<OwnerDetails>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Message Which Owner?'),
          children: allOwners.map((owner) => SimpleDialogOption(
            onPressed: () => Navigator.pop(context, owner),
            child: ListTile(
              leading: Picon(PiconsDuotone.user),
              title: Text(owner.username),
              subtitle: Text(owner.email),
              dense: true,
            ),
          )).toList(),
        ),
      );
      if (selected == null || !mounted) return;
      selectedOwnerDetails = selected;
    } else {
      selectedOwnerDetails = _dog.ownerDetails!;
    }

    final subjectController = TextEditingController(text: 'Re: ${_dog.name}');
    final messageController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Message ${selectedOwnerDetails.username}'),
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
          ownerId: selectedOwnerDetails.userId,
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
  }

  Future<void> _deleteDog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Dog'),
        content: Text(
          'Are you sure you want to delete ${_dog.name}? '
          'This will permanently remove all associated photos, requests, and data. '
          'This action cannot be undone.',
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

    if (confirmed != true || !mounted) return;

    try {
      await _dataService.deleteDog(_dog.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_dog.name} has been deleted'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, 'deleted');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete dog: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _assignOwner() async {
    List<OwnerProfile> owners = [];
    try {
      owners = await _dataService.getOwners();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load users: $e')),
        );
      }
      return;
    }

    if (!mounted) return;

    final currentOwnerId = _dog.ownerDetails?.userId;
    final currentAdditionalIds = _dog.additionalOwners.map((o) => o.userId).toSet();
    int? selectedOwnerId = currentOwnerId;
    Set<int> selectedAdditionalIds = Set.from(currentAdditionalIds);

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Assign ${_dog.name}'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Primary Owner', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int?>(
                    value: selectedOwnerId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('No owner', style: TextStyle(color: Colors.grey)),
                      ),
                      ...owners.map((o) => DropdownMenuItem<int?>(
                        value: o.userId,
                        child: Text(o.username),
                      )),
                    ],
                    onChanged: (value) {
                      setDialogState(() {
                        selectedOwnerId = value;
                        selectedAdditionalIds.remove(value);
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Text('Additional Owners', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  ...owners
                    .where((o) => o.userId != selectedOwnerId)
                    .map((o) => CheckboxListTile(
                      title: Text(o.username),
                      subtitle: Text(o.email, style: const TextStyle(fontSize: 12)),
                      value: selectedAdditionalIds.contains(o.userId),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (checked) {
                        setDialogState(() {
                          if (checked == true) {
                            selectedAdditionalIds.add(o.userId);
                          } else {
                            selectedAdditionalIds.remove(o.userId);
                          }
                        });
                      },
                    )),
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
              onPressed: () => Navigator.pop(context, {
                'owner': selectedOwnerId,
                'additional_owners': selectedAdditionalIds.toList(),
              }),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;

    try {
      final updatedDog = await _dataService.assignDogToUser(
        _dog.id,
        owner: result['owner'] as int?,
        removeOwner: result['owner'] == null,
        additionalOwners: (result['additional_owners'] as List<int>),
      );
      if (mounted) {
        setState(() => _dog = updatedDog);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Owner updated'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to assign owner: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  List<DateTime> _getUpcomingDaycareDates() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final threeMonthsLater = DateTime(now.year, now.month + 3, now.day);

    final dayNumbers = _dog.daysInDaycare.map((d) => d.dayNumber).toSet();

    DateTime norm(DateTime d) => DateTime(d.year, d.month, d.day);
    bool isActive(DateChangeRequest r) => r.status != RequestStatus.denied;

    // Dates removed from the schedule: cancellations and the *original* date of
    // a change (a change moves a day from its original date to its new date).
    final removedDates = _requests
        .where((r) =>
            isActive(r) &&
            (r.requestType == RequestType.cancel ||
                r.requestType == RequestType.change) &&
            r.originalDate != null)
        .map((r) => norm(r.originalDate!))
        .toSet();

    // Dates added to the schedule: additional days and the *new* date of a
    // change. These may fall on non-recurring weekdays, so add them explicitly.
    final addedDates = _requests
        .where((r) =>
            isActive(r) &&
            (r.requestType == RequestType.addDay ||
                r.requestType == RequestType.change) &&
            r.newDate != null)
        .map((r) => norm(r.newDate!))
        .where((d) => !d.isBefore(today) && d.isBefore(threeMonthsLater))
        .toSet();

    final dates = <DateTime>{};
    var current = today;
    while (current.isBefore(threeMonthsLater)) {
      if (dayNumbers.contains(current.weekday)) {
        dates.add(norm(current));
      }
      current = current.add(const Duration(days: 1));
    }
    dates.addAll(addedDates);
    dates.removeAll(removedDates);

    final result = dates.toList()..sort();
    return result;
  }

  bool _isConfirmed(DateTime date) {
    final now = DateTime.now();
    final oneMonthLater = DateTime(now.year, now.month + 1, now.day);
    return date.isBefore(oneMonthLater);
  }

  void _showDateChangeRequest(DateTime date) {
    final isConfirmed = _isConfirmed(date);
    final formattedDate = ukDateWithDay(date);

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
                    Picon(PiconsDuotone.warning, color: Colors.orange[800]),
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
    final formattedDate = ukDateWithDay(originalDate);

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
                    Picon(PiconsDuotone.warning, color: Colors.red[800]),
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

  /// Latest date selectable on the dog's daycare calendar.
  ///
  /// Staff can edit which days a dog is at (or not at) daycare effectively
  /// without limit — years into the future. Owners are still capped a few
  /// months ahead, since their changes are *requests* that staff must approve.
  DateTime _calendarLastDay(DateTime now) => widget.isStaff
      ? DateTime(now.year + 5, now.month, now.day)
      : DateTime(now.year, now.month + 3, now.day);

  Future<void> _showDatePicker(DateTime originalDate, bool isConfirmed) async {
    final now = DateTime.now();
    final newDate = await showDatePicker(
      context: context,
      initialDate: originalDate.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: _calendarLastDay(now),
      helpText: 'Select new date',
    );

    if (newDate != null && mounted) {
      _showChangeConfirmation(originalDate, newDate, isConfirmed);
    }
  }

  void _showChangeConfirmation(DateTime originalDate, DateTime newDate, bool isConfirmed) {
    final formattedOriginal = ukDateWithDay(originalDate);
    final formattedNew = ukDateWithDay(newDate);

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
                Picon(PiconsDuotone.arrowRight),
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
                    Picon(PiconsDuotone.info, color: Colors.orange[800]),
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

  Future<void> _showRequestAdditionalDays() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    Set<DateTime> selectedDates = {};

    // Build set of dates the dog is already booked for
    final bookedWeekdays = _dog.daysInDaycare.map((d) => d.dayNumber).toSet();

    // Dates with existing pending/approved ADD_DAY requests
    final pendingAddDayDates = _requests
        .where((r) =>
            r.requestType == RequestType.addDay &&
            r.status != RequestStatus.denied &&
            r.newDate != null)
        .map((r) => DateTime(r.newDate!.year, r.newDate!.month, r.newDate!.day))
        .toSet();

    // Dates with approved cancellations (these are no longer booked)
    final cancelledDates = _requests
        .where((r) =>
            r.requestType == RequestType.cancel &&
            r.status == RequestStatus.approved &&
            r.originalDate != null)
        .map((r) => DateTime(r.originalDate!.year, r.originalDate!.month, r.originalDate!.day))
        .toSet();

    bool isAlreadyBooked(DateTime day) {
      final normalized = DateTime(day.year, day.month, day.day);
      // Check if there's an approved cancellation for this date
      if (cancelledDates.contains(normalized)) return false;
      // Check if it's a regular daycare day
      if (bookedWeekdays.contains(day.weekday)) return true;
      // Check if there's already a pending/approved ADD_DAY request
      if (pendingAddDayDates.contains(normalized)) return true;
      return false;
    }

    final result = await showDialog<Set<DateTime>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Request Additional Days'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Tap dates to select them for ${_dog.name}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 350,
                    child: TableCalendar(
                      firstDay: today,
                      lastDay: _calendarLastDay(now),
                      focusedDay: today,
                      startingDayOfWeek: StartingDayOfWeek.monday,
                      calendarFormat: CalendarFormat.month,
                      enabledDayPredicate: (day) => !isAlreadyBooked(day),
                      selectedDayPredicate: (day) {
                        return selectedDates.contains(DateTime(day.year, day.month, day.day));
                      },
                      onDaySelected: (selectedDay, focusedDay) {
                        final normalized = DateTime(selectedDay.year, selectedDay.month, selectedDay.day);
                        setDialogState(() {
                          if (selectedDates.contains(normalized)) {
                            selectedDates.remove(normalized);
                          } else {
                            selectedDates.add(normalized);
                          }
                        });
                      },
                      calendarStyle: CalendarStyle(
                        selectedDecoration: BoxDecoration(
                          color: Colors.green[600],
                          shape: BoxShape.circle,
                        ),
                        todayDecoration: BoxDecoration(
                          color: Colors.green[100],
                          shape: BoxShape.circle,
                        ),
                        todayTextStyle: TextStyle(color: Colors.green[800]!),
                      ),
                      headerStyle: const HeaderStyle(
                        formatButtonVisible: false,
                        titleCentered: true,
                      ),
                    ),
                  ),
                  if (selectedDates.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${selectedDates.length} day${selectedDates.length == 1 ? '' : 's'} selected',
                      style: TextStyle(
                        color: Colors.green[700],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: selectedDates.isEmpty
                    ? null
                    : () => Navigator.pop(context, selectedDates),
                child: Text(selectedDates.isEmpty
                    ? 'Select dates'
                    : 'Request ${selectedDates.length} day${selectedDates.length == 1 ? '' : 's'}'),
              ),
            ],
          );
        },
      ),
    );

    if (result != null && result.isNotEmpty && mounted) {
      _showAdditionalDaysConfirmation(result);
    }
  }

  void _showAdditionalDaysConfirmation(Set<DateTime> dates) {
    final sortedDates = dates.toList()..sort();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Request ${_dog.name} to attend daycare on:'),
            const SizedBox(height: 12),
            ...sortedDates.map((date) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green[300]!),
                ),
                child: Row(
                  children: [
                    Picon(PiconsDuotone.plusCircle, color: Colors.green[800], size: 18),
                    const SizedBox(width: 8),
                    Text(
                      ukDateWithDay(date),
                      style: TextStyle(
                        color: Colors.green[800],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            )),
            const SizedBox(height: 8),
            if (!widget.isStaff)
              Text(
                'Each day will need to be approved by staff.',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            if (widget.isStaff)
              Text(
                'These days will be added immediately.',
                style: TextStyle(color: Colors.green[700], fontSize: 13),
              ),
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
              await _submitAdditionalDayRequests(sortedDates);
            },
            child: Text('Submit ${sortedDates.length} Request${sortedDates.length == 1 ? '' : 's'}'),
          ),
        ],
      ),
    );
  }

  Future<void> _submitAdditionalDayRequests(List<DateTime> dates) async {
    int successCount = 0;
    int failCount = 0;

    for (final date in dates) {
      try {
        await _dataService.submitAdditionalDayRequest(
          dogId: _dog.id,
          requestedDate: date,
        );
        successCount++;
      } catch (e) {
        failCount++;
      }
    }

    if (mounted) {
      if (failCount == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(successCount == 1
                ? 'Additional day request submitted'
                : '$successCount additional day requests submitted'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$successCount submitted, $failCount failed'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      _loadRequests();
    }
  }

  Future<void> _loadBoardingRequests() async {
    setState(() => _loadingBoardingRequests = true);
    try {
      final allRequests = await _dataService.getBoardingRequests();
      if (mounted) {
        final dogId = int.parse(_dog.id);
        setState(() {
          _boardingRequests = allRequests
              .where((r) => r.dogIds.contains(dogId))
              .toList();
          _loadingBoardingRequests = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingBoardingRequests = false);
      }
    }
  }

  void _showRequestBoarding() {
    DateTimeRange? selectedRange;
    final instructionsController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text('Request Boarding for ${_dog.name}'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select Dates',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () async {
                      final now = DateTime.now();
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: now,
                        lastDate: now.add(const Duration(days: 365)),
                        initialDateRange: selectedRange,
                      );
                      if (picked != null) {
                        setDialogState(() {
                          selectedRange = picked;
                        });
                      }
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Picon(PiconsDuotone.calendarDots),
                        labelText: 'Boarding Dates',
                        isDense: true,
                      ),
                      child: Text(
                        selectedRange != null
                            ? '${ukDate(selectedRange!.start)} - ${ukDate(selectedRange!.end)}'
                            : 'Tap to select dates',
                        style: TextStyle(
                          color: selectedRange != null ? Colors.black : Colors.grey[600],
                        ),
                      ),
                    ),
                  ),
                  if (selectedRange != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${selectedRange!.end.difference(selectedRange!.start).inDays} night${selectedRange!.end.difference(selectedRange!.start).inDays == 1 ? '' : 's'}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'Special Instructions',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: instructionsController,
                    decoration: const InputDecoration(
                      hintText: 'Feeding, meds, special care...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 3,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: selectedRange == null
                    ? null
                    : () async {
                        Navigator.pop(context);
                        await _submitBoardingRequest(
                          selectedRange!,
                          instructionsController.text.trim().isEmpty
                              ? null
                              : instructionsController.text.trim(),
                        );
                      },
                child: const Text('Submit'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _submitBoardingRequest(DateTimeRange dateRange, String? instructions) async {
    try {
      await _dataService.createBoardingRequest(
        dogIds: [int.parse(_dog.id)],
        startDate: dateRange.start,
        endDate: dateRange.end,
        specialInstructions: instructions,
        ownerId: _dog.ownerDetails?.userId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Boarding request submitted'),
            backgroundColor: Colors.green,
          ),
        );
        _loadBoardingRequests();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildBoardingRequestsSection() {
    if (_loadingBoardingRequests) {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_boardingRequests.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.only(top: 8),
      elevation: 0,
      color: Colors.white.withOpacity(0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ExpansionTile(
        title: Text(
          'Boarding Requests (${_boardingRequests.length})',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).primaryColor,
            fontSize: 14,
          ),
        ),
        initiallyExpanded: false,
        childrenPadding: const EdgeInsets.all(8),
        children: _boardingRequests.map((request) {
          final nights = request.endDate.difference(request.startDate).inDays;
          return Card(
            elevation: 1,
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              dense: true,
              leading: Picon(
                PiconsDuotone.bed,
                color: _getBoardingStatusColor(request.status),
              ),
              title: Text(
                '${ukDate(request.startDate)} - ${ukDate(request.endDate)} ($nights night${nights == 1 ? '' : 's'})',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
              subtitle: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _getBoardingStatusColor(request.status).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      request.status.toString().split('.').last.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        color: _getBoardingStatusColor(request.status),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (request.specialInstructions != null && request.specialInstructions!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Picon(PiconsDuotone.notepad, size: 14, color: Colors.grey[500]),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Color _getBoardingStatusColor(BoardingRequestStatus status) {
    switch (status) {
      case BoardingRequestStatus.pending:
        return Colors.orange;
      case BoardingRequestStatus.approved:
        return Colors.green;
      case BoardingRequestStatus.denied:
        return Colors.red;
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
            leading: Picon(
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
            ),
            title: Text(
              request.requestType == RequestType.cancel
                  ? 'Cancel ${ukDateWithDay(request.originalDate!)}'
                  : request.requestType == RequestType.addDay
                      ? 'Add ${ukDateWithDay(request.newDate!)}'
                      : '${ukDateWithDay(request.originalDate!)} → ${ukDateWithDay(request.newDate!)}',
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

  String _formatAge(DateTime dob) {
    final now = DateTime.now();
    int years = now.year - dob.year;
    int months = now.month - dob.month;
    if (now.day < dob.day) months -= 1;
    if (months < 0) {
      years -= 1;
      months += 12;
    }
    if (years > 0 && months > 0) return '$years yr ${months}m';
    if (years > 0) return years == 1 ? '1 yr' : '$years yrs';
    return months == 1 ? '1 month' : '$months months';
  }

  Widget _infoChip({required PiconDuotoneData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primaryLight.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Picon(icon, size: 14, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.primary)),
        ],
      ),
    );
  }

  Widget _infoBlock({required PiconDuotoneData icon, required String title, required String body, Color? accent}) {
    final color = accent ?? AppColors.primary;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Picon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
          const SizedBox(height: 4),
          Text(body, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildDogInfoSection() {
    final chips = <Widget>[];
    if (_dog.sex != null) {
      chips.add(_infoChip(
        icon: PiconsDuotone.pawPrint,
        label: _dog.sex == DogSex.male ? 'Male' : 'Female',
      ));
    }
    if (_dog.dateOfBirth != null) {
      chips.add(_infoChip(
        icon: PiconsDuotone.cake,
        label: _formatAge(_dog.dateOfBirth!),
      ));
    }
    if (_dog.sex != null) {
      chips.add(_infoChip(
        icon: PiconsDuotone.heart,
        label: _dog.isSpayed
            ? (_dog.sex == DogSex.male ? 'Neutered' : 'Spayed')
            : (_dog.sex == DogSex.male ? 'Not neutered' : 'Not spayed'),
      ));
    }
    chips.add(_infoChip(
      icon: PiconsDuotone.calendarDots,
      label: _dog.scheduleType.displayName,
    ));
    if (_dog.preferredDropoffTime != null && widget.isStaff) {
      chips.add(_infoChip(
        icon: PiconsDuotone.clock,
        label: 'Dropoff ${_dog.preferredDropoffTime!.displayName}',
      ));
    }

    final transportLines = <String>[];
    if (widget.isStaff) {
      if (_dog.ownerBringsDefault) {
        final t = _dog.ownerBringsDefaultTime;
        transportLines.add(
          'Owner brings${t != null ? ' at ${t.format(context)}' : ''}',
        );
      }
      if (_dog.ownerCollectsDefault) {
        final t = _dog.ownerCollectsDefaultTime;
        transportLines.add(
          'Owner collects${t != null ? ' at ${t.format(context)}' : ''}',
        );
      }
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 6, runSpacing: 6, children: chips),
          if (_dog.foodInstructions != null && _dog.foodInstructions!.trim().isNotEmpty)
            _infoBlock(
              icon: PiconsDuotone.forkKnife,
              title: 'Food',
              body: _dog.foodInstructions!,
            ),
          if (_dog.medicalNotes != null && _dog.medicalNotes!.trim().isNotEmpty)
            _infoBlock(
              icon: PiconsDuotone.firstAid,
              title: 'Medical / Injuries',
              body: _dog.medicalNotes!,
              accent: Colors.red[700],
            ),
          if (_dog.registeredVet != null && _dog.registeredVet!.trim().isNotEmpty)
            _infoBlock(
              icon: PiconsDuotone.stethoscope,
              title: 'Registered Vet',
              body: _dog.registeredVet!,
            ),
          if (transportLines.isNotEmpty)
            _infoBlock(
              icon: PiconsDuotone.car,
              title: 'Transport',
              body: transportLines.join('\n'),
            ),
        ],
      ),
    );
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
              icon: Picon(PiconsDuotone.chatCircle),
              tooltip: 'Contact Owner',
              onPressed: _contactOwner,
            ),
          IconButton(
            icon: Picon(PiconsDuotone.pencilSimple),
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
          if (widget.isStaff)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'assign_owner') {
                  _assignOwner();
                } else if (value == 'delete') {
                  _deleteDog();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'assign_owner',
                  child: Row(
                    children: [
                      Picon(PiconsDuotone.userPlus, color: Colors.black54),
                      SizedBox(width: 8),
                      Text('Assign Owner'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Picon(PiconsDuotone.trash, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Delete Dog', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
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
                              ? Picon(PiconsDuotone.pawPrint, size: 40)
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
                                icon: Picon(PiconsDuotone.user, size: 18),
                                label: Text(_dog.additionalOwners.isEmpty
                                  ? 'Owner Info'
                                  : 'Owners (${1 + _dog.additionalOwners.length})'),
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
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.primaryLight.withOpacity(0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Picon(PiconsDuotone.clock, color: AppColors.primary, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'Pickup: 08:00 - 09:30',
                                style: TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Picon(PiconsDuotone.clock, color: AppColors.primary, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'Drop-off: 15:30 - 16:45',
                                style: TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Every effort is made to stick within these times, but our drivers are at the behest of traffic.',
                            style: TextStyle(color: AppColors.primary.withOpacity(0.7), fontSize: 11, fontStyle: FontStyle.italic),
                          ),
                        ],
                      ),
                    ),
                  ],
                  _buildDogInfoSection(),
                  // Show upcoming booked dates whenever the dog has any — this
                  // includes ad-hoc dogs whose dates come from additional-day
                  // or change requests (they have no recurring daycare_days),
                  // so owners/staff can still tap a date to edit or cancel it.
                  if (upcomingDates.isNotEmpty) ...[
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
                  if (!widget.isStaff) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showRequestAdditionalDays,
                        icon: Picon(PiconsDuotone.plusCircle),
                        label: const Text('Request Additional Days'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.green[700],
                          side: BorderSide(color: Colors.green[300]!),
                        ),
                      ),
                    ),
                  ],
                  if (widget.isStaff) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showRequestAdditionalDays,
                        icon: Picon(PiconsDuotone.plusCircle),
                        label: const Text('Add Additional Days'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.green[700],
                          side: BorderSide(color: Colors.green[300]!),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DogNotesScreen(
                                dogId: int.parse(_dog.id),
                                dogName: _dog.name,
                              ),
                            ),
                          );
                        },
                        icon: Picon(PiconsDuotone.notepad),
                        label: const Text('Compatibility & Notes'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: const BorderSide(color: AppColors.primaryLight),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _showRequestBoarding,
                      icon: Picon(PiconsDuotone.bed),
                      label: const Text('Request Boarding'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.deepPurple,
                        side: BorderSide(color: Colors.deepPurple[200]!),
                      ),
                    ),
                  ),
                  _buildRequestsSection(),
                  if (widget.isStaff) _buildBoardingRequestsSection(),
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
