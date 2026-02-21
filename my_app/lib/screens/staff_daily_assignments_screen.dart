import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/daily_dog_assignment.dart';
import '../models/dog.dart';
import '../services/data_service.dart';

class StaffDailyAssignmentsScreen extends StatefulWidget {
  final bool canAssignDogs;

  const StaffDailyAssignmentsScreen({super.key, this.canAssignDogs = false});

  @override
  State<StaffDailyAssignmentsScreen> createState() =>
      StaffDailyAssignmentsScreenState();
}

class StaffDailyAssignmentsScreenState
    extends State<StaffDailyAssignmentsScreen> {
  final DataService _dataService = ApiDataService();

  // Cache: date string -> assignments
  final Map<String, List<DailyDogAssignment>> _assignmentCache = {};
  final Set<String> _loadingDates = {};

  late final List<DateTime> _dateOptions = _generateWeekdays();
  late final PageController _pageController;
  final ScrollController _dateScrollController = ScrollController();

  int? _selectedStaffId;
  List<Map<String, dynamic>> _staffMembers = [];

  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    // Start on today if it's a weekday, otherwise the first available weekday
    final today = DateTime.now();
    final todayIndex = _dateOptions.indexWhere((d) => _isSameDay(d, today));
    final initialIndex = todayIndex >= 0 ? todayIndex : 0;
    _selectedDate = _dateOptions[initialIndex];
    _pageController = PageController(initialPage: initialIndex);
    _loadStaffMembers();
    _loadAssignmentsForDate(_selectedDate);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _dateScrollController.dispose();
    super.dispose();
  }

  List<DateTime> _generateWeekdays() {
    final today = DateTime.now();
    // Start from today (or next Monday if weekend)
    var start = DateTime(today.year, today.month, today.day);
    if (start.weekday == DateTime.saturday) {
      start = start.add(const Duration(days: 2));
    } else if (start.weekday == DateTime.sunday) {
      start = start.add(const Duration(days: 1));
    }
    final List<DateTime> weekdays = [];
    var current = start;
    while (weekdays.length < 10) {
      if (current.weekday >= DateTime.monday && current.weekday <= DateTime.friday) {
        weekdays.add(current);
      }
      current = current.add(const Duration(days: 1));
    }
    return weekdays;
  }

  Future<void> _loadStaffMembers() async {
    if (!widget.canAssignDogs) return;
    try {
      final staff = await _dataService.getStaffMembers();
      if (mounted) {
        setState(() => _staffMembers = staff);
      }
    } catch (_) {}
  }

  String _dateKey(DateTime date) => '${date.year}-${date.month}-${date.day}';

  Future<void> _loadAssignmentsForDate(DateTime date, {bool forceReload = false}) async {
    if (!mounted) return;
    final key = _dateKey(date);
    if (!forceReload && _assignmentCache.containsKey(key)) return;
    setState(() => _loadingDates.add(key));
    try {
      final assignments = widget.canAssignDogs
          ? await _dataService.getTodayAssignments(date: date)
          : await _dataService.getMyAssignments(date: date);
      if (mounted) {
        setState(() {
          _assignmentCache[key] = assignments;
          _loadingDates.remove(key);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingDates.remove(key));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load assignments: $e')),
        );
      }
    }
  }

  // Keep this for compatibility with dialogs that call _loadAssignments()
  Future<void> _loadAssignments() => _loadAssignmentsForDate(_selectedDate, forceReload: true);

  List<DailyDogAssignment> _getFilteredAssignments(DateTime date) {
    final all = _assignmentCache[_dateKey(date)] ?? [];
    if (_selectedStaffId == null) return all;
    return all.where((a) => a.staffMemberId == _selectedStaffId).toList();
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _updateStatus(
      DailyDogAssignment assignment, AssignmentStatus newStatus) async {
    try {
      final updated =
          await _dataService.updateAssignmentStatus(assignment.id, newStatus);
      if (mounted) {
        setState(() {
          final key = _dateKey(_selectedDate);
          final assignments = _assignmentCache[key];
          if (assignments != null) {
            final index = assignments.indexWhere((a) => a.id == assignment.id);
            if (index != -1) {
              assignments[index] = updated;
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update status: $e')),
        );
      }
    }
  }

  Future<void> _showAssignDogsDialog() async {
    List<Dog> unassigned;
    List<Map<String, dynamic>> staffMembers = [];
    Map<String, dynamic> suggestions = {};
    try {
      unassigned = await _dataService.getUnassignedDogs(date: _selectedDate);
      if (widget.canAssignDogs) {
        staffMembers = await _dataService.getStaffMembers();
        suggestions = await _dataService.getSuggestedAssignments(date: _selectedDate);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load data: $e')),
        );
      }
      return;
    }

    if (!mounted) return;

    final dateLabel = _isSameDay(_selectedDate, DateTime.now())
        ? 'today'
        : DateFormat('EEE d MMM').format(_selectedDate);

    if (unassigned.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('All dogs scheduled for $dateLabel are already assigned.')),
      );
      return;
    }

    final selected = <int>{};
    int? selectedStaffId;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(widget.canAssignDogs ? 'Assign Dogs ($dateLabel)' : 'Assign Dogs to Me'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.canAssignDogs) ...[
                  DropdownButtonFormField<int>(
                    decoration: const InputDecoration(
                      labelText: 'Assign to Staff Member',
                      border: OutlineInputBorder(),
                    ),
                    value: selectedStaffId,
                    items: staffMembers.map((staff) {
                      final name = (staff['first_name'] != null && staff['first_name'].toString().isNotEmpty)
                          ? staff['first_name']
                          : staff['username'];
                      return DropdownMenuItem<int>(
                        value: staff['id'] as int,
                        child: Text(name.toString()),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setDialogState(() => selectedStaffId = value);
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: unassigned.length,
                    itemBuilder: (context, index) {
                      final dog = unassigned[index];
                      final dogId = int.parse(dog.id);
                      final suggestion = suggestions[dogId.toString()];
                      String? suggestedName;
                      if (suggestion != null) {
                        suggestedName = suggestion['staff_member_name'];
                      }
                      return CheckboxListTile(
                        value: selected.contains(dogId),
                        onChanged: (checked) {
                          setDialogState(() {
                            if (checked == true) {
                              selected.add(dogId);
                            } else {
                              selected.remove(dogId);
                            }
                          });
                        },
                        title: Text(dog.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (dog.ownerDetails != null)
                              Text('Owner: ${dog.ownerDetails!.username}'),
                            if (suggestedName != null)
                              Text(
                                'Usually: $suggestedName',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                          ],
                        ),
                        secondary: dog.profileImageUrl != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: CachedNetworkImage(
                                  imageUrl: dog.profileImageUrl!,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : const CircleAvatar(child: Icon(Icons.pets)),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.isEmpty || (widget.canAssignDogs && selectedStaffId == null)
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Assign'),
            ),
          ],
        ),
      ),
    );

    if (result == true && selected.isNotEmpty) {
      try {
        if (widget.canAssignDogs && selectedStaffId != null) {
          await _dataService.assignDogs(selected.toList(), selectedStaffId!, date: _selectedDate);
        } else {
          await _dataService.assignDogsToMe(selected.toList(), date: _selectedDate);
        }
        await _loadAssignments();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to assign dogs: $e')),
          );
        }
      }
    }
  }

  AssignmentStatus? _nextStatus(AssignmentStatus current) {
    switch (current) {
      case AssignmentStatus.assigned:
        return AssignmentStatus.pickedUp;
      case AssignmentStatus.pickedUp:
        return AssignmentStatus.atDaycare;
      case AssignmentStatus.atDaycare:
        return AssignmentStatus.droppedOff;
      case AssignmentStatus.droppedOff:
        return null;
    }
  }

  AssignmentStatus? _previousStatus(AssignmentStatus current) {
    switch (current) {
      case AssignmentStatus.assigned:
        return null;
      case AssignmentStatus.pickedUp:
        return AssignmentStatus.assigned;
      case AssignmentStatus.atDaycare:
        return AssignmentStatus.pickedUp;
      case AssignmentStatus.droppedOff:
        return AssignmentStatus.atDaycare;
    }
  }

  IconData _statusIcon(AssignmentStatus status) {
    switch (status) {
      case AssignmentStatus.assigned:
        return Icons.assignment;
      case AssignmentStatus.pickedUp:
        return Icons.directions_car;
      case AssignmentStatus.atDaycare:
        return Icons.home;
      case AssignmentStatus.droppedOff:
        return Icons.check_circle;
    }
  }

  Color _statusColor(AssignmentStatus status) {
    switch (status) {
      case AssignmentStatus.assigned:
        return Colors.orange;
      case AssignmentStatus.pickedUp:
        return Colors.blue;
      case AssignmentStatus.atDaycare:
        return Colors.purple;
      case AssignmentStatus.droppedOff:
        return Colors.green;
    }
  }

  void _showAssignmentOptionsSheet(DailyDogAssignment assignment) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Reassign'),
              subtitle: Text('Assign ${assignment.dogName} to a different staff member'),
              onTap: () {
                Navigator.pop(context);
                _showReassignDialog(assignment);
              },
            ),
            ListTile(
              leading: Icon(Icons.person_remove, color: Colors.red[700]),
              title: Text('Unassign', style: TextStyle(color: Colors.red[700])),
              subtitle: Text('Remove ${assignment.dogName} from ${assignment.staffMemberName}'),
              onTap: () {
                Navigator.pop(context);
                _confirmUnassign(assignment);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmUnassign(DailyDogAssignment assignment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unassign Dog'),
        content: Text(
          'Are you sure you want to unassign ${assignment.dogName} from ${assignment.staffMemberName}? '
          'The dog will appear in the unassigned list and can be reassigned later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Unassign'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _dataService.unassignDog(assignment.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${assignment.dogName} has been unassigned'),
              backgroundColor: Colors.green,
            ),
          );
        }
        await _loadAssignments();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to unassign: $e')),
          );
        }
      }
    }
  }

  Future<void> _showReassignDialog(DailyDogAssignment assignment) async {
    List<Map<String, dynamic>> staffMembers;
    try {
      staffMembers = await _dataService.getStaffMembers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load staff: $e')),
        );
      }
      return;
    }

    // Remove the currently assigned staff member from the list
    staffMembers.removeWhere((s) => s['id'] == assignment.staffMemberId);

    if (!mounted) return;

    if (staffMembers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other staff members available.')),
      );
      return;
    }

    int? selectedStaffId;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Reassign ${assignment.dogName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Currently assigned to ${assignment.staffMemberName}',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                decoration: const InputDecoration(
                  labelText: 'Reassign to',
                  border: OutlineInputBorder(),
                ),
                value: selectedStaffId,
                items: staffMembers.map((staff) {
                  final name = (staff['first_name'] != null &&
                          staff['first_name'].toString().isNotEmpty)
                      ? staff['first_name']
                      : staff['username'];
                  return DropdownMenuItem<int>(
                    value: staff['id'] as int,
                    child: Text(name.toString()),
                  );
                }).toList(),
                onChanged: (value) {
                  setDialogState(() => selectedStaffId = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selectedStaffId == null
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Reassign'),
            ),
          ],
        ),
      ),
    );

    if (result == true && selectedStaffId != null) {
      try {
        await _dataService.reassignDog(assignment.id, selectedStaffId!);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Dog reassigned successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
        await _loadAssignments();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to reassign: $e')),
          );
        }
      }
    }
  }

  void _showPickupInstructions(DailyDogAssignment assignment) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.info_outline),
                  const SizedBox(width: 8),
                  Text(
                    'Pickup Instructions - ${assignment.dogName}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ],
              ),
              const Divider(height: 24),
              Text(
                assignment.pickupInstructions!,
                style: const TextStyle(fontSize: 15, height: 1.5),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openMaps(String address) async {
    final uri = Uri.parse('https://maps.apple.com/?q=${Uri.encodeComponent(address)}');
    final geoUri = Uri.parse('geo:0,0?q=${Uri.encodeComponent(address)}');
    // Try geo: first (works on Android), fall back to maps URL
    if (await canLaunchUrl(geoUri)) {
      await launchUrl(geoUri);
    } else if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _callPhone(String phone) async {
    final uri = Uri.parse('tel:${Uri.encodeComponent(phone)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// Expose the assign dogs action so the parent can use it in a FAB.
  void assignDogs() => _showAssignDogsDialog();

  /// Expose the traffic alert action so the parent can use it in the app bar.
  void showTrafficAlert() => _showTrafficAlertDialog();

  Future<void> _showTrafficAlertDialog() async {
    final detailController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.traffic, color: Colors.orange),
            SizedBox(width: 8),
            Text('Traffic Alert'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Send a traffic delay notification to all owners with dogs scheduled today. '
              'Which service is affected?',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: detailController,
              decoration: const InputDecoration(
                labelText: 'Additional detail (optional)',
                hintText: 'e.g. Accident on M1, expect 20 min delay',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'pickup'),
            icon: const Icon(Icons.arrow_upward, size: 18),
            label: const Text('Pickup'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'dropoff'),
            icon: const Icon(Icons.arrow_downward, size: 18),
            label: const Text('Drop-off'),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        final detail = detailController.text.trim();
        await _dataService.sendTrafficAlert(result, date: _selectedDate, detail: detail.isNotEmpty ? detail : null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Traffic alert sent to all owners for ${result == 'pickup' ? 'pickup' : 'drop-off'}',
              ),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to send traffic alert: $e')),
          );
        }
      }
    }
  }

  void _scrollToDateChip(int index) {
    // Approximate chip width (~70) to scroll selected chip into view
    final targetOffset = (index * 78.0) - 100;
    if (_dateScrollController.hasClients) {
      _dateScrollController.animateTo(
        targetOffset.clamp(0.0, _dateScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Widget _buildDateSelector() {
    final today = DateTime.now();
    final dateFormat = DateFormat('EEE');
    final dayFormat = DateFormat('d');

    return SizedBox(
      height: 72,
      child: ListView.builder(
        controller: _dateScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _dateOptions.length,
        itemBuilder: (context, index) {
          final date = _dateOptions[index];
          final isSelected = _isSameDay(date, _selectedDate);
          final isToday = _isSameDay(date, today);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              selected: isSelected,
              onSelected: (_) {
                setState(() => _selectedDate = date);
                _pageController.animateToPage(
                  index,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
                _loadAssignmentsForDate(date);
              },
              label: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isToday ? 'Today' : dateFormat.format(date),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  Text(
                    dayFormat.format(date),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStaffFilter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int?>(
              decoration: const InputDecoration(
                labelText: 'Filter by staff',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
              ),
              value: _selectedStaffId,
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('All Staff'),
                ),
                ..._staffMembers.map((staff) {
                  final name = (staff['first_name'] != null && staff['first_name'].toString().isNotEmpty)
                      ? staff['first_name']
                      : staff['username'];
                  return DropdownMenuItem<int?>(
                    value: staff['id'] as int,
                    child: Text(name.toString()),
                  );
                }),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedStaffId = value;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildDateSelector(),
        if (widget.canAssignDogs && _staffMembers.isNotEmpty) ...[
          _buildStaffFilter(),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _dateOptions.length,
            onPageChanged: (index) {
              final date = _dateOptions[index];
              setState(() => _selectedDate = date);
              _scrollToDateChip(index);
              _loadAssignmentsForDate(date);
            },
            itemBuilder: (context, index) {
              final date = _dateOptions[index];
              final key = _dateKey(date);
              final isLoading = _loadingDates.contains(key);
              final filtered = _getFilteredAssignments(date);

              if (isLoading && !_assignmentCache.containsKey(key)) {
                return const Center(child: CircularProgressIndicator());
              }

              if (filtered.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.pets, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        _selectedStaffId != null
                            ? 'No dogs assigned to this staff member'
                            : 'No dogs assigned for this date',
                        style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      const Text('Tap the + button to assign dogs.'),
                    ],
                  ),
                );
              }

              return RefreshIndicator(
                onRefresh: () => _loadAssignmentsForDate(date, forceReload: true),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    return _buildAssignmentCard(filtered[i]);
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAssignmentCard(DailyDogAssignment assignment) {
    final next = _nextStatus(assignment.status);
    final previous = _previousStatus(assignment.status);
    final statusColor = _statusColor(assignment.status);

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Dog info row
            Row(
              children: [
                if (assignment.dogProfileImage != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: CachedNetworkImage(
                      imageUrl: assignment.dogProfileImage!,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: 48,
                        height: 48,
                        color: Colors.grey[200],
                        child: const Icon(Icons.pets),
                      ),
                      errorWidget: (context, url, error) =>
                          const CircleAvatar(radius: 24, child: Icon(Icons.pets)),
                    ),
                  )
                else
                  const CircleAvatar(radius: 24, child: Icon(Icons.pets)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        assignment.dogName,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      Text(
                        'Owner: ${assignment.ownerName}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (widget.canAssignDogs)
                        Text(
                          'Staff: ${assignment.staffMemberName}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                    ],
                  ),
                ),
                // Status button with dropdown
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'reassign') {
                      _showReassignDialog(assignment);
                    } else if (value == 'unassign') {
                      _confirmUnassign(assignment);
                    } else if (value == 'next' && next != null) {
                      _updateStatus(assignment, next);
                    } else if (value == 'previous' && previous != null) {
                      _updateStatus(assignment, previous);
                    }
                  },
                  itemBuilder: (context) => [
                    if (next != null)
                      PopupMenuItem(
                        value: 'next',
                        child: Row(
                          children: [
                            Icon(_statusIcon(next), size: 18),
                            const SizedBox(width: 8),
                            Text('Mark ${next.displayName}'),
                          ],
                        ),
                      ),
                    if (previous != null)
                      PopupMenuItem(
                        value: 'previous',
                        child: Row(
                          children: [
                            Icon(_statusIcon(previous), size: 18),
                            const SizedBox(width: 8),
                            Text('Revert to ${previous.displayName}'),
                          ],
                        ),
                      ),
                    if (widget.canAssignDogs) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'reassign',
                        child: Row(
                          children: [
                            const Icon(Icons.swap_horiz, size: 18),
                            const SizedBox(width: 8),
                            const Text('Reassign'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'unassign',
                        child: Row(
                          children: [
                            Icon(Icons.person_remove, size: 18, color: Colors.red[700]),
                            const SizedBox(width: 8),
                            Text('Unassign', style: TextStyle(color: Colors.red[700])),
                          ],
                        ),
                      ),
                    ],
                  ],
                  child: Chip(
                    avatar: Icon(_statusIcon(assignment.status),
                        size: 18, color: statusColor),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          assignment.status.displayName,
                          style: TextStyle(color: statusColor, fontSize: 12),
                        ),
                        Icon(Icons.arrow_drop_down, size: 16, color: statusColor),
                      ],
                    ),
                    backgroundColor: statusColor.withValues(alpha: 0.1),
                    side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Pickup info
            if (assignment.ownerAddress != null &&
                assignment.ownerAddress!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  onTap: () => _openMaps(assignment.ownerAddress!),
                  child: Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 16, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          assignment.ownerAddress!,
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (assignment.ownerPhone != null &&
                assignment.ownerPhone!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  onTap: () => _callPhone(assignment.ownerPhone!),
                  child: Row(
                    children: [
                      Icon(Icons.phone,
                          size: 16, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        assignment.ownerPhone!,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (assignment.pickupInstructions != null &&
                assignment.pickupInstructions!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  onTap: () => _showPickupInstructions(assignment),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        'Pickup Instructions',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

          ],
        ),
      ),
    );
  }
}
