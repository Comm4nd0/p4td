import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
import '../models/daily_dog_assignment.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../services/cache_service.dart';
import '../utils/date_formats.dart';

enum _SortOption {
  nameAsc('Name (A-Z)'),
  nameDesc('Name (Z-A)'),
  staffMember('Staff Member'),
  status('Status');

  final String label;
  const _SortOption(this.label);
}

/// Shows all dogs for a given date in a single flat list — both assigned
/// dogs and rostered-but-unassigned dogs (excluding ad-hoc dogs, which are
/// handled via the dedicated "Add Dog to Day" flow).
class AllDogsTodayScreen extends StatefulWidget {
  final DateTime date;
  final List<DailyDogAssignment> assignments;
  final List<Dog> unassignedDogs;
  final bool canAssignDogs;
  final bool isStaff;
  final List<Map<String, dynamic>> staffMembers;
  final Set<int> availableStaffIds;

  const AllDogsTodayScreen({
    super.key,
    required this.date,
    required this.assignments,
    this.unassignedDogs = const [],
    this.canAssignDogs = false,
    this.isStaff = false,
    this.staffMembers = const [],
    this.availableStaffIds = const {},
  });

  @override
  State<AllDogsTodayScreen> createState() => _AllDogsTodayScreenState();
}

class _AllDogsTodayScreenState extends State<AllDogsTodayScreen> {
  static const _sortCacheKey = 'all_dogs_today';
  final DataService _dataService = ApiDataService();
  final CacheService _cacheService = CacheService();
  late List<DailyDogAssignment> _assignments;
  late List<Dog> _unassignedDogs;
  _SortOption _sortOption = _SortOption.nameAsc;
  bool _dataChanged = false;
  String _searchQuery = '';
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    _assignments = List.of(widget.assignments);
    _unassignedDogs = List.of(widget.unassignedDogs);
    _restoreSortPreference();
    _applySorting();
  }

  void _restoreSortPreference() {
    final saved = _cacheService.getCachedSortPreference(_sortCacheKey);
    if (saved != null) {
      for (final option in _SortOption.values) {
        if (option.name == saved) {
          _sortOption = option;
          break;
        }
      }
    }
  }

  void _applySorting() {
    switch (_sortOption) {
      case _SortOption.nameAsc:
        _assignments.sort((a, b) => a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase()));
        _unassignedDogs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _SortOption.nameDesc:
        _assignments.sort((a, b) => b.dogName.toLowerCase().compareTo(a.dogName.toLowerCase()));
        _unassignedDogs.sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      case _SortOption.staffMember:
        _assignments.sort((a, b) {
          final cmp = a.staffMemberName.toLowerCase().compareTo(b.staffMemberName.toLowerCase());
          if (cmp != 0) return cmp;
          return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
        });
        _unassignedDogs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _SortOption.status:
        _assignments.sort((a, b) {
          final cmp = a.status.index.compareTo(b.status.index);
          if (cmp != 0) return cmp;
          return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
        });
        _unassignedDogs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
  }

  List<DailyDogAssignment> get _filteredAssignments {
    if (_searchQuery.isEmpty) return _assignments;
    final query = _searchQuery.toLowerCase();
    return _assignments.where((a) =>
      a.dogName.toLowerCase().contains(query) ||
      a.ownerName.toLowerCase().contains(query) ||
      a.staffMemberName.toLowerCase().contains(query)
    ).toList();
  }

  List<Dog> get _filteredUnassignedDogs {
    if (_searchQuery.isEmpty) return _unassignedDogs;
    final query = _searchQuery.toLowerCase();
    return _unassignedDogs.where((d) =>
      d.name.toLowerCase().contains(query) ||
      (d.ownerDetails?.username.toLowerCase().contains(query) ?? false)
    ).toList();
  }

  Future<void> _reloadAll() async {
    try {
      final assignments = await _dataService.getTodayAssignments(date: widget.date);
      final unassigned = await _dataService.getUnassignedDogs(date: widget.date);
      if (mounted) {
        setState(() {
          _assignments = assignments;
          _unassignedDogs = unassigned;
          _applySorting();
          _dataChanged = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reload: $e')),
        );
      }
    }
  }

  Future<void> _updateStatus(DailyDogAssignment assignment, AssignmentStatus newStatus) async {
    try {
      final updated = await _dataService.updateAssignmentStatus(assignment.id, newStatus);
      if (mounted) {
        setState(() {
          final index = _assignments.indexWhere((a) => a.id == assignment.id);
          if (index != -1) {
            _assignments[index] = updated;
          }
          _dataChanged = true;
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

  AssignmentStatus? _nextStatus(AssignmentStatus current) {
    switch (current) {
      case AssignmentStatus.assigned: return AssignmentStatus.pickedUp;
      case AssignmentStatus.pickedUp: return AssignmentStatus.droppedOff;
      case AssignmentStatus.droppedOff: return null;
    }
  }

  AssignmentStatus? _previousStatus(AssignmentStatus current) {
    switch (current) {
      case AssignmentStatus.assigned: return null;
      case AssignmentStatus.pickedUp: return AssignmentStatus.assigned;
      case AssignmentStatus.droppedOff: return AssignmentStatus.pickedUp;
    }
  }

  PiconDuotoneData _statusIcon(AssignmentStatus status) {
    switch (status) {
      case AssignmentStatus.assigned: return PiconsDuotone.clipboardText;
      case AssignmentStatus.pickedUp: return PiconsDuotone.pawPrint;
      case AssignmentStatus.droppedOff: return PiconsDuotone.checkCircle;
    }
  }

  Color _statusColor(AssignmentStatus status) {
    switch (status) {
      case AssignmentStatus.assigned: return Colors.orange;
      case AssignmentStatus.pickedUp: return AppColors.primary;
      case AssignmentStatus.droppedOff: return Colors.green;
    }
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _openMaps(String address) async {
    final uri = Uri.parse('https://maps.apple.com/?q=${Uri.encodeComponent(address)}');
    final geoUri = Uri.parse('geo:0,0?q=${Uri.encodeComponent(address)}');
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
              Row(children: [
                Picon(PiconsDuotone.info),
                const SizedBox(width: 8),
                Text('Pickup Instructions - ${assignment.dogName}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ]),
              const Divider(height: 24),
              Text(assignment.pickupInstructions!, style: const TextStyle(fontSize: 15, height: 1.5)),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Assignment-card actions (mirror staff_dog_detail_screen) ─────

  Future<AssignmentScope?> _promptAssignmentScope({
    required String title,
    required String justThisDayLabel,
    required String fromNowOnLabel,
  }) {
    return showDialog<AssignmentScope>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: const Text('Apply this change to only this day, or to every week going forward?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, AssignmentScope.justThisDay), child: Text(justThisDayLabel)),
          FilledButton(onPressed: () => Navigator.pop(context, AssignmentScope.fromNowOn), child: Text(fromNowOnLabel)),
        ],
      ),
    );
  }

  Future<void> _confirmUnassign(DailyDogAssignment assignment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unassign Dog'),
        content: Text('Are you sure you want to unassign ${assignment.dogName} from ${assignment.staffMemberName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Unassign'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final scope = await _promptAssignmentScope(
      title: 'Unassign Scope',
      justThisDayLabel: 'Just this day',
      fromNowOnLabel: 'From now on',
    );
    if (scope == null) return;

    try {
      await _dataService.unassignDog(assignment.id, scope: scope);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${assignment.dogName} has been unassigned'), backgroundColor: Colors.green),
        );
      }
      await _reloadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to unassign: $e')));
      }
    }
  }

  Future<void> _confirmRemoveFromDay(DailyDogAssignment assignment) async {
    final dateLabel = ukDateWithDay(widget.date);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from Day'),
        content: Text('Remove ${assignment.dogName} from $dateLabel? This will cancel their booking for this day.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _dataService.unassignDog(assignment.id, scope: AssignmentScope.justThisDay);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${assignment.dogName} removed from $dateLabel'), backgroundColor: Colors.green),
        );
      }
      await _reloadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to remove: $e')));
      }
    }
  }

  Future<void> _showReassignDialog(DailyDogAssignment assignment) async {
    final picked = await _pickStaffMember(
      title: 'Reassign ${assignment.dogName}',
      currentStaffId: assignment.staffMemberId,
      subtitle: 'Currently assigned to ${assignment.staffMemberName}',
      confirmLabel: 'Reassign',
    );
    if (picked == null || !mounted) return;

    final scope = await _promptAssignmentScope(
      title: 'Reassign Scope',
      justThisDayLabel: 'Just this day',
      fromNowOnLabel: 'From now on',
    );
    if (scope == null) return;
    try {
      await _dataService.reassignDog(assignment.id, picked, scope: scope);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dog reassigned successfully'), backgroundColor: Colors.green),
        );
      }
      await _reloadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to reassign: $e')));
      }
    }
  }

  Future<void> _showTransportDialog(DailyDogAssignment assignment) async {
    bool? brings = assignment.ownerBrings;
    bool? collects = assignment.ownerCollects;
    TimeOfDay? bringsTime = assignment.ownerBringsTime ?? assignment.effectiveOwnerBringsTime;
    TimeOfDay? collectsTime = assignment.ownerCollectsTime ?? assignment.effectiveOwnerCollectsTime;

    final effectiveBringsAtOpen = assignment.effectiveOwnerBrings;
    final effectiveCollectsAtOpen = assignment.effectiveOwnerCollects;

    String chipLabel(bool? value, bool effective) {
      if (value == null) return 'Default (${effective ? 'owner' : 'staff'})';
      return value ? 'Owner' : 'Staff';
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Transport: ${assignment.dogName}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Drop-off (morning)',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                SegmentedButton<Object>(
                  segments: const [
                    ButtonSegment(value: 'default', label: Text('Default')),
                    ButtonSegment(value: true, label: Text('Owner')),
                    ButtonSegment(value: false, label: Text('Staff')),
                  ],
                  selected: {brings == null ? 'default' : brings!},
                  onSelectionChanged: (s) {
                    setDialogState(() {
                      final v = s.first;
                      brings = v == 'default' ? null : v as bool;
                    });
                  },
                ),
                Text(brings == null
                    ? chipLabel(brings, effectiveBringsAtOpen)
                    : '',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
                if ((brings ?? effectiveBringsAtOpen) == true) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Picon(PiconsDuotone.clock, size: 18),
                    label: Text(bringsTime == null
                        ? 'Set drop-off time'
                        : 'Drop-off at ${_formatTime(bringsTime!)}'),
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: bringsTime ?? const TimeOfDay(hour: 8, minute: 0),
                      );
                      if (picked != null) setDialogState(() => bringsTime = picked);
                    },
                  ),
                  if (bringsTime != null)
                    TextButton(
                      onPressed: () => setDialogState(() => bringsTime = null),
                      child: const Text('Clear time', style: TextStyle(fontSize: 12)),
                    ),
                ],
                const Divider(height: 24),
                Text('Pick-up (evening)',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                SegmentedButton<Object>(
                  segments: const [
                    ButtonSegment(value: 'default', label: Text('Default')),
                    ButtonSegment(value: true, label: Text('Owner')),
                    ButtonSegment(value: false, label: Text('Staff')),
                  ],
                  selected: {collects == null ? 'default' : collects!},
                  onSelectionChanged: (s) {
                    setDialogState(() {
                      final v = s.first;
                      collects = v == 'default' ? null : v as bool;
                    });
                  },
                ),
                Text(collects == null
                    ? chipLabel(collects, effectiveCollectsAtOpen)
                    : '',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
                if ((collects ?? effectiveCollectsAtOpen) == true) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Picon(PiconsDuotone.clock, size: 18),
                    label: Text(collectsTime == null
                        ? 'Set pick-up time'
                        : 'Pick-up at ${_formatTime(collectsTime!)}'),
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: collectsTime ?? const TimeOfDay(hour: 17, minute: 0),
                      );
                      if (picked != null) setDialogState(() => collectsTime = picked);
                    },
                  ),
                  if (collectsTime != null)
                    TextButton(
                      onPressed: () => setDialogState(() => collectsTime = null),
                      child: const Text('Clear time', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) return;

    try {
      final updated = await _dataService.setAssignmentTransport(
        assignment.id,
        ownerBrings: brings,
        ownerCollects: collects,
        ownerBringsTime: (brings ?? effectiveBringsAtOpen) ? bringsTime : null,
        ownerCollectsTime: (collects ?? effectiveCollectsAtOpen) ? collectsTime : null,
      );
      if (mounted) {
        setState(() {
          final index = _assignments.indexWhere((a) => a.id == assignment.id);
          if (index != -1) _assignments[index] = updated;
          _dataChanged = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transport updated for ${assignment.dogName}'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update transport: $e')));
      }
    }
  }

  // ─── Unassigned-card actions ──────────────────────────────────────

  Future<int?> _pickStaffMember({
    required String title,
    int? currentStaffId,
    String? subtitle,
    String confirmLabel = 'Assign',
  }) async {
    List<Map<String, dynamic>> staffMembers = List.of(widget.staffMembers);
    Set<int> availableIds = Set.of(widget.availableStaffIds);
    if (staffMembers.isEmpty) {
      try {
        staffMembers = await _dataService.getStaffMembers();
        try {
          final available = await _dataService.getAvailableStaffForDate(widget.date);
          availableIds = available.map((s) => s['id'] as int).toSet();
        } catch (_) {
          availableIds = staffMembers.map((s) => s['id'] as int).toSet();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load staff: $e')));
        }
        return null;
      }
    }

    if (currentStaffId != null) {
      staffMembers = staffMembers.where((s) => s['id'] != currentStaffId).toList();
    }
    staffMembers.sort((a, b) {
      final aAvail = availableIds.isEmpty || availableIds.contains(a['id'] as int);
      final bAvail = availableIds.isEmpty || availableIds.contains(b['id'] as int);
      if (aAvail && !bAvail) return -1;
      if (!aAvail && bAvail) return 1;
      return 0;
    });

    if (!mounted || staffMembers.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No staff members available.')));
      }
      return null;
    }

    int? picked;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (subtitle != null) ...[
                Text(subtitle, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<int>(
                decoration: const InputDecoration(labelText: 'Staff member', border: OutlineInputBorder()),
                value: picked,
                items: staffMembers.map((s) {
                  final name = (s['first_name'] != null && s['first_name'].toString().isNotEmpty)
                      ? s['first_name'].toString() : s['username'].toString();
                  final staffId = s['id'] as int;
                  final isAvailable = availableIds.isEmpty || availableIds.contains(staffId);
                  return DropdownMenuItem<int>(
                    value: staffId,
                    child: Row(children: [
                      Picon(PiconsDuotone.circle, size: 10, color: isAvailable ? AppColors.success : AppColors.grey400),
                      const SizedBox(width: 8),
                      Text(name, style: TextStyle(color: isAvailable ? null : AppColors.grey500)),
                      if (!isAvailable) Text(' (off)', style: TextStyle(fontSize: 11, color: AppColors.grey400)),
                    ]),
                  );
                }).toList(),
                onChanged: (v) => setDialogState(() => picked = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: picked == null ? null : () => Navigator.pop(context, true), child: Text(confirmLabel)),
          ],
        ),
      ),
    );
    return (result == true) ? picked : null;
  }

  Future<void> _assignToMe(Dog dog) async {
    try {
      final result = await _dataService.assignDogsToMe([int.parse(dog.id)], date: widget.date);
      if (mounted) {
        if (result.hasSkipped) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name}: ${result.skipped.first.reason}'), backgroundColor: Colors.orange),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name} assigned to you'), backgroundColor: Colors.green),
          );
        }
      }
      await _reloadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to assign: $e')));
      }
    }
  }

  Future<void> _assignToStaff(Dog dog) async {
    final staffId = await _pickStaffMember(
      title: 'Assign ${dog.name}',
      confirmLabel: 'Assign',
    );
    if (staffId == null || !mounted) return;
    try {
      final result = await _dataService.assignDogs([int.parse(dog.id)], staffId, date: widget.date);
      if (mounted) {
        if (result.hasSkipped) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name}: ${result.skipped.first.reason}'), backgroundColor: Colors.orange),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name} assigned'), backgroundColor: Colors.green),
          );
        }
      }
      await _reloadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to assign: $e')));
      }
    }
  }

  Future<void> _confirmRemoveUnassignedFromDay(Dog dog) async {
    final dateLabel = ukDateWithDay(widget.date);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from Day'),
        content: Text('Remove ${dog.name} from $dateLabel? This will cancel their booking for this day.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _dataService.removeDogFromDay(int.parse(dog.id), widget.date);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${dog.name} removed from $dateLabel'), backgroundColor: Colors.green),
        );
      }
      await _reloadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to remove: $e')));
      }
    }
  }

  // ─── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final dateLabel = ukDateWithDay(widget.date);
    final filteredAssignments = _filteredAssignments;
    final filteredUnassigned = _filteredUnassignedDogs;

    // Status summary counts
    final assignedCount = _assignments.where((a) => a.status == AssignmentStatus.assigned).length;
    final withTeamCount = _assignments.where((a) => a.status == AssignmentStatus.pickedUp).length;
    final droppedOffCount = _assignments.where((a) => a.status == AssignmentStatus.droppedOff).length;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _dataChanged) {
          // Parent dashboard will refresh on return
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: _showSearch
              ? TextField(
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: InputDecoration(
                    hintText: 'Search dogs, owners, staff…',
                    hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                    border: InputBorder.none,
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                )
              : Text('All Dogs — $dateLabel'),
          actions: [
            IconButton(
              icon: Picon(_showSearch ? PiconsDuotone.x : PiconsDuotone.magnifyingGlass),
              tooltip: _showSearch ? 'Close search' : 'Search',
              onPressed: () => setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) _searchQuery = '';
              }),
            ),
            _buildSortButton(),
          ],
        ),
        body: Column(
          children: [
            // Status summary bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Theme.of(context).cardColor,
              child: Row(
                children: [
                  _buildStatusChip('Assigned', assignedCount, Colors.orange),
                  const SizedBox(width: 8),
                  _buildStatusChip('With Team', withTeamCount, AppColors.primary),
                  const SizedBox(width: 8),
                  _buildStatusChip('Done', droppedOffCount, Colors.green),
                  if (_unassignedDogs.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _buildStatusChip('Unassigned', _unassignedDogs.length, Colors.red),
                  ],
                ],
              ),
            ),
            // Dog list
            Expanded(
              child: filteredAssignments.isEmpty && filteredUnassigned.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Picon(PiconsDuotone.pawPrint, size: 64, color: Colors.grey[400]),
                          const SizedBox(height: 16),
                          Text(
                            _searchQuery.isNotEmpty ? 'No dogs match your search' : 'No dogs for this date',
                            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _reloadAll,
                      child: _sortOption == _SortOption.staffMember
                          ? _buildGroupedByStaffList(filteredAssignments, filteredUnassigned)
                          : _buildFlatList(filteredAssignments, filteredUnassigned),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(String label, int count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Text('$count', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
            Text(label, style: TextStyle(fontSize: 9, color: color), overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _buildSortButton() {
    return PopupMenuButton<_SortOption>(
      icon: Picon(PiconsDuotone.sortAscending),
      tooltip: 'Sort dogs',
      onSelected: (option) {
        setState(() {
          _sortOption = option;
          _applySorting();
        });
        _cacheService.cacheSortPreference(_sortCacheKey, option.name);
      },
      itemBuilder: (context) => _SortOption.values
          .map((option) => PopupMenuItem(
                value: option,
                child: Row(children: [
                  if (_sortOption == option) Picon(PiconsDuotone.check, size: 18) else const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Text(option.label),
                ]),
              ))
          .toList(),
    );
  }

  Widget _buildUnassignedSectionHeader(int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: [
          Picon(PiconsDuotone.warning, size: 18, color: Colors.red[700]),
          const SizedBox(width: 8),
          Text('Unassigned',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.red[700],
                  )),
          const SizedBox(width: 8),
          Text('$count', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        ],
      ),
    );
  }

  Widget _buildFlatList(List<DailyDogAssignment> assignments, List<Dog> unassigned) {
    final staffPickups = assignments.where((a) => !a.effectiveOwnerBrings).toList();
    final ownerDropoffs = assignments.where((a) => a.effectiveOwnerBrings).toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      children: [
        if (unassigned.isNotEmpty) ...[
          _buildUnassignedSectionHeader(unassigned.length),
          ...unassigned.map((d) => _buildUnassignedCard(d)),
          const SizedBox(height: 12),
        ],
        ...staffPickups.map((a) => _buildAssignmentCard(a)),
        if (ownerDropoffs.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Row(
              children: [
                Picon(PiconsDuotone.houseLine, size: 18, color: Colors.teal),
                const SizedBox(width: 8),
                Text('Owner Drop-offs',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text('${ownerDropoffs.length}', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              ],
            ),
          ),
          ...ownerDropoffs.map((a) => _buildAssignmentCard(a)),
        ],
      ],
    );
  }

  Widget _buildGroupedByStaffList(List<DailyDogAssignment> assignments, List<Dog> unassigned) {
    // Group by staff member
    final Map<int, List<DailyDogAssignment>> groups = {};
    final Map<int, String> staffNames = {};
    for (final a in assignments) {
      groups.putIfAbsent(a.staffMemberId, () => []).add(a);
      staffNames[a.staffMemberId] = a.staffMemberName;
    }
    final sortedStaffIds = groups.keys.toList()
      ..sort((a, b) => staffNames[a]!.toLowerCase().compareTo(staffNames[b]!.toLowerCase()));

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      children: [
        if (unassigned.isNotEmpty) ...[
          _buildUnassignedSectionHeader(unassigned.length),
          ...unassigned.map((d) => _buildUnassignedCard(d)),
          const SizedBox(height: 12),
        ],
        ...sortedStaffIds.asMap().entries.map((entry) {
          final i = entry.key;
          final staffId = entry.value;
          final staffAssignments = groups[staffId]!;
          final staffName = staffNames[staffId]!;
          final staffPickups = staffAssignments.where((a) => !a.effectiveOwnerBrings).toList();
          final ownerDropoffs = staffAssignments.where((a) => a.effectiveOwnerBrings).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (i > 0) const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: AppColors.primary,
                      child: Text(staffName[0], style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 8),
                    Text(staffName,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Text('${staffAssignments.length} dog${staffAssignments.length == 1 ? '' : 's'}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                  ],
                ),
              ),
              ...staffPickups.map((a) => _buildAssignmentCard(a)),
              if (ownerDropoffs.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 6, left: 4),
                  child: Row(
                    children: [
                      Picon(PiconsDuotone.houseLine, size: 16, color: Colors.teal),
                      const SizedBox(width: 6),
                      Text('Owner Drop-offs',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: Colors.teal)),
                    ],
                  ),
                ),
                ...ownerDropoffs.map((a) => _buildAssignmentCard(a)),
              ],
            ],
          );
        }),
      ],
    );
  }

  Widget _buildUnassignedCard(Dog dog) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.red.shade200, width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (dog.profileImageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: CachedNetworkImage(
                  imageUrl: dog.profileImageUrl!,
                  width: 44, height: 44, fit: BoxFit.cover,
                  placeholder: (context, url) => Container(
                    width: 44, height: 44, color: Colors.grey[200],
                    child: Picon(PiconsDuotone.pawPrint),
                  ),
                  errorWidget: (context, url, error) =>
                      CircleAvatar(radius: 22, child: Picon(PiconsDuotone.pawPrint)),
                ),
              )
            else
              CircleAvatar(radius: 22, child: Picon(PiconsDuotone.pawPrint)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dog.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  if (dog.ownerDetails != null)
                    Text('Owner: ${dog.ownerDetails!.username}',
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            // Action menu
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'assign_to_me':
                    _assignToMe(dog);
                  case 'assign_to_staff':
                    _assignToStaff(dog);
                  case 'remove_from_day':
                    _confirmRemoveUnassignedFromDay(dog);
                }
              },
              itemBuilder: (context) => [
                if (widget.isStaff)
                  PopupMenuItem(
                    value: 'assign_to_me',
                    child: Row(children: [
                      Picon(PiconsDuotone.userPlus, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      const Text('Assign to me'),
                    ]),
                  ),
                if (widget.canAssignDogs)
                  PopupMenuItem(
                    value: 'assign_to_staff',
                    child: Row(children: [
                      Picon(PiconsDuotone.users, size: 18),
                      const SizedBox(width: 8),
                      const Text('Assign to staff…'),
                    ]),
                  ),
                if (widget.canAssignDogs) ...[
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'remove_from_day',
                    child: Row(children: [
                      Picon(PiconsDuotone.calendarX, size: 18, color: Colors.red[900]),
                      const SizedBox(width: 8),
                      Text('Remove from this day', style: TextStyle(color: Colors.red[900])),
                    ]),
                  ),
                ],
              ],
              child: Chip(
                avatar: Picon(PiconsDuotone.warning, size: 16, color: Colors.red[700]),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Unassigned', style: TextStyle(color: Colors.red[700], fontSize: 11)),
                    Picon(PiconsDuotone.caretDown, size: 14, color: Colors.red[700]),
                  ],
                ),
                backgroundColor: Colors.red.withValues(alpha: 0.1),
                side: BorderSide(color: Colors.red.withValues(alpha: 0.3)),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssignmentCard(DailyDogAssignment assignment) {
    final next = _nextStatus(assignment.status);
    final previous = _previousStatus(assignment.status);
    final statusColor = _statusColor(assignment.status);

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 8),
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
                    borderRadius: BorderRadius.circular(22),
                    child: CachedNetworkImage(
                      imageUrl: assignment.dogProfileImage!,
                      width: 44, height: 44, fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: 44, height: 44, color: Colors.grey[200],
                        child: Picon(PiconsDuotone.pawPrint),
                      ),
                      errorWidget: (context, url, error) =>
                          CircleAvatar(radius: 22, child: Picon(PiconsDuotone.pawPrint)),
                    ),
                  )
                else
                  CircleAvatar(radius: 22, child: Picon(PiconsDuotone.pawPrint)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(assignment.dogName,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                      Text('Owner: ${assignment.ownerName}', style: Theme.of(context).textTheme.bodySmall),
                      if (_sortOption != _SortOption.staffMember)
                        Text('Staff: ${assignment.staffMemberName}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.primary)),
                      if (assignment.isBoarding)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(children: [
                            Picon(PiconsDuotone.house, size: 14, color: Colors.deepPurple),
                            const SizedBox(width: 4),
                            Text('Boarding',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.deepPurple, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                    ],
                  ),
                ),
                // Status chip with full action menu
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'next':
                        if (next != null) _updateStatus(assignment, next);
                      case 'previous':
                        if (previous != null) _updateStatus(assignment, previous);
                      case 'transport':
                        _showTransportDialog(assignment);
                      case 'reassign':
                        _showReassignDialog(assignment);
                      case 'unassign':
                        _confirmUnassign(assignment);
                      case 'remove_from_day':
                        _confirmRemoveFromDay(assignment);
                    }
                  },
                  itemBuilder: (context) => [
                    if (next != null)
                      PopupMenuItem(
                        value: 'next',
                        child: Row(children: [
                          Picon(_statusIcon(next), size: 18),
                          const SizedBox(width: 8),
                          Text('Mark ${next.displayName}'),
                        ]),
                      ),
                    if (previous != null)
                      PopupMenuItem(
                        value: 'previous',
                        child: Row(children: [
                          Picon(_statusIcon(previous), size: 18),
                          const SizedBox(width: 8),
                          Text('Revert to ${previous.displayName}'),
                        ]),
                      ),
                    if (widget.canAssignDogs) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'transport',
                        child: Row(children: [
                          Picon(PiconsDuotone.car, size: 18),
                          const SizedBox(width: 8),
                          const Text('Transport…'),
                        ]),
                      ),
                      PopupMenuItem(
                        value: 'reassign',
                        child: Row(children: [
                          Picon(PiconsDuotone.arrowsLeftRight, size: 18),
                          const SizedBox(width: 8),
                          const Text('Reassign'),
                        ]),
                      ),
                      PopupMenuItem(
                        value: 'unassign',
                        child: Row(children: [
                          Picon(PiconsDuotone.userMinus, size: 18, color: Colors.red[700]),
                          const SizedBox(width: 8),
                          Text('Unassign', style: TextStyle(color: Colors.red[700])),
                        ]),
                      ),
                      PopupMenuItem(
                        value: 'remove_from_day',
                        child: Row(children: [
                          Picon(PiconsDuotone.calendarX, size: 18, color: Colors.red[900]),
                          const SizedBox(width: 8),
                          Text('Remove from this day', style: TextStyle(color: Colors.red[900])),
                        ]),
                      ),
                    ],
                  ],
                  child: Chip(
                    avatar: Picon(_statusIcon(assignment.status), size: 16, color: statusColor),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(assignment.status.displayName, style: TextStyle(color: statusColor, fontSize: 11)),
                        Picon(PiconsDuotone.caretDown, size: 14, color: statusColor),
                      ],
                    ),
                    backgroundColor: statusColor.withValues(alpha: 0.1),
                    side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Transport indicators
            if (assignment.effectiveOwnerBrings || assignment.effectiveOwnerCollects)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (assignment.effectiveOwnerBrings)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.teal.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.teal.withValues(alpha: 0.35)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Picon(PiconsDuotone.houseLine, size: 14, color: Colors.teal),
                          const SizedBox(width: 4),
                          Text(
                            assignment.effectiveOwnerBringsTime != null
                                ? 'Owner drops off ${_formatTime(assignment.effectiveOwnerBringsTime!)}'
                                : 'Owner drops off',
                            style: const TextStyle(fontSize: 12, color: Colors.teal),
                          ),
                        ]),
                      ),
                    if (assignment.effectiveOwnerCollects)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.indigo.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.indigo.withValues(alpha: 0.35)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Picon(PiconsDuotone.houseLine, size: 14, color: Colors.indigo),
                          const SizedBox(width: 4),
                          Text(
                            assignment.effectiveOwnerCollectsTime != null
                                ? 'Owner picks up ${_formatTime(assignment.effectiveOwnerCollectsTime!)}'
                                : 'Owner picks up',
                            style: const TextStyle(fontSize: 12, color: Colors.indigo),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
            // Address
            if (assignment.ownerAddress != null && assignment.ownerAddress!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  onTap: () => _openMaps(assignment.ownerAddress!),
                  child: Row(children: [
                    Picon(PiconsDuotone.mapPin, size: 16, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(assignment.ownerAddress!,
                          style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline)),
                    ),
                  ]),
                ),
              ),
            // Phone
            if (assignment.ownerPhone != null && assignment.ownerPhone!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  onTap: () => _callPhone(assignment.ownerPhone!),
                  child: Row(children: [
                    Picon(PiconsDuotone.phone, size: 16, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 4),
                    Text(assignment.ownerPhone!,
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline)),
                  ]),
                ),
              ),
            // Pickup instructions
            if (assignment.pickupInstructions != null && assignment.pickupInstructions!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  onTap: () => _showPickupInstructions(assignment),
                  child: Row(children: [
                    Picon(PiconsDuotone.info, size: 16, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 4),
                    Text('Pickup Instructions',
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline)),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
