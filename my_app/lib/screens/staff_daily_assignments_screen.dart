import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
  List<DailyDogAssignment> _myAssignments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAssignments();
  }

  Future<void> _loadAssignments() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final assignments = widget.canAssignDogs
          ? await _dataService.getTodayAssignments()
          : await _dataService.getMyAssignments();
      if (mounted) {
        setState(() {
          _myAssignments = assignments;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load assignments: $e')),
        );
      }
    }
  }

  Future<void> _updateStatus(
      DailyDogAssignment assignment, AssignmentStatus newStatus) async {
    try {
      final updated =
          await _dataService.updateAssignmentStatus(assignment.id, newStatus);
      if (mounted) {
        setState(() {
          final index =
              _myAssignments.indexWhere((a) => a.id == assignment.id);
          if (index != -1) {
            _myAssignments[index] = updated;
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
    try {
      unassigned = await _dataService.getUnassignedDogs();
      if (widget.canAssignDogs) {
        staffMembers = await _dataService.getStaffMembers();
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

    if (unassigned.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All dogs scheduled for today are already assigned.')),
      );
      return;
    }

    final selected = <int>{};
    int? selectedStaffId;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(widget.canAssignDogs ? 'Assign Dogs' : 'Assign Dogs to Me'),
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
                        subtitle: dog.ownerDetails != null
                            ? Text('Owner: ${dog.ownerDetails!.username}')
                            : null,
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
          await _dataService.assignDogs(selected.toList(), selectedStaffId!);
        } else {
          await _dataService.assignDogsToMe(selected.toList());
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

  /// Expose the assign dogs action so the parent can use it in a FAB.
  void assignDogs() => _showAssignDogsDialog();

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_myAssignments.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pets, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No dogs assigned to you today',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            const Text('Tap the button below to assign dogs.'),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAssignments,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
        itemCount: _myAssignments.length,
        itemBuilder: (context, index) {
          final assignment = _myAssignments[index];
          return _buildAssignmentCard(assignment);
        },
      ),
    );
  }

  Widget _buildAssignmentCard(DailyDogAssignment assignment) {
    final next = _nextStatus(assignment.status);
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
                // Status chip
                Chip(
                  avatar: Icon(_statusIcon(assignment.status),
                      size: 18, color: statusColor),
                  label: Text(
                    assignment.status.displayName,
                    style: TextStyle(color: statusColor, fontSize: 12),
                  ),
                  backgroundColor: statusColor.withValues(alpha: 0.1),
                  side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Pickup info
            if (assignment.ownerAddress != null &&
                assignment.ownerAddress!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.location_on,
                        size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        assignment.ownerAddress!,
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey[700]),
                      ),
                    ),
                  ],
                ),
              ),
            if (assignment.ownerPhone != null &&
                assignment.ownerPhone!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.phone, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      assignment.ownerPhone!,
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey[700]),
                    ),
                  ],
                ),
              ),
            if (assignment.pickupInstructions != null &&
                assignment.pickupInstructions!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        assignment.pickupInstructions!,
                        style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[700],
                            fontStyle: FontStyle.italic),
                      ),
                    ),
                  ],
                ),
              ),

            // Action button
            if (next != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _updateStatus(assignment, next),
                  icon: Icon(_statusIcon(next)),
                  label: Text('Mark as ${next.displayName}'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
