import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
import '../models/daily_dog_assignment.dart';
import '../services/data_service.dart';
import '../services/cache_service.dart';
import '../utils/date_formats.dart';
import '../widgets/dog_quick_info_sheet.dart';
import 'dog_home_screen.dart';
import 'pickup_map_screen.dart';

enum DogSortOption {
  nameAsc('Name (A-Z)'),
  nameDesc('Name (Z-A)'),
  pickupOrder('Pickup Order'),
  custom('Custom Order');

  final String label;
  const DogSortOption(this.label);
}

/// Detail page showing one staff member's dogs for a specific date.
/// Pushed from the unified dashboard when tapping a staff card.
class StaffDogDetailScreen extends StatefulWidget {
  final int? staffMemberId;
  final String staffMemberName;
  final DateTime date;
  final List<DailyDogAssignment> assignments;
  final bool canAssignDogs;

  const StaffDogDetailScreen({
    super.key,
    required this.staffMemberId,
    required this.staffMemberName,
    required this.date,
    required this.assignments,
    required this.canAssignDogs,
  });

  @override
  State<StaffDogDetailScreen> createState() => _StaffDogDetailScreenState();
}

class _StaffDogDetailScreenState extends State<StaffDogDetailScreen> {
  static const _sortCacheKey = 'staff_dog_detail';
  final DataService _dataService = ApiDataService();
  final CacheService _cacheService = CacheService();
  late List<DailyDogAssignment> _assignments;
  DogSortOption _sortOption = DogSortOption.nameAsc;
  bool _dataChanged = false;
  bool _reordering = false;
  bool _openingMap = false;

  @override
  void initState() {
    super.initState();
    _assignments = List.of(widget.assignments);
    // If any assignment has a non-zero sort_order, the user has previously
    // customised the order — default to custom sort to honour it.
    final hasCustomOrder = _assignments.any((a) => a.sortOrder != 0);
    if (hasCustomOrder) {
      _sortOption = DogSortOption.custom;
    }
    _restoreSortPreference();
    _applySorting();
  }

  void _restoreSortPreference() {
    final saved = _cacheService.getCachedSortPreference(_sortCacheKey);
    if (saved != null) {
      for (final option in DogSortOption.values) {
        if (option.name == saved) {
          _sortOption = option;
          break;
        }
      }
    }
  }

  void _applySorting() {
    switch (_sortOption) {
      case DogSortOption.nameAsc:
        _assignments.sort((a, b) => a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase()));
      case DogSortOption.nameDesc:
        _assignments.sort((a, b) => b.dogName.toLowerCase().compareTo(a.dogName.toLowerCase()));
      case DogSortOption.pickupOrder:
        _assignments.sort((a, b) {
          final addrA = a.ownerAddress?.toLowerCase() ?? '';
          final addrB = b.ownerAddress?.toLowerCase() ?? '';
          final cmp = addrA.compareTo(addrB);
          if (cmp != 0) return cmp;
          return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
        });
      case DogSortOption.custom:
        // Sort by the persisted sort_order from the API, then by name
        _assignments.sort((a, b) {
          final cmp = a.sortOrder.compareTo(b.sortOrder);
          if (cmp != 0) return cmp;
          return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
        });
    }
  }

  Future<void> _reloadAssignments() async {
    try {
      final all = await _dataService.getTodayAssignments(date: widget.date);
      if (mounted) {
        setState(() {
          if (widget.staffMemberId != null) {
            _assignments = all.where((a) => a.staffMemberId == widget.staffMemberId).toList();
          } else {
            // "Unassigned" — this shouldn't happen since unassigned dogs don't have assignments
            _assignments = all;
          }
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

  /// Single tap on a dog card: quick-info sheet, with optional follow-on
  /// navigation to the full profile.
  Future<void> _openQuickInfo(DailyDogAssignment assignment) async {
    final dog = await DogQuickInfoSheet.show(context, assignment: assignment);
    if (dog == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DogHomeScreen(dog: dog, isStaff: true)),
    );
    if (mounted) _reloadAssignments();
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
          SnackBar(content: Text('${assignment.dogName} has been unassigned'), backgroundColor: AppColors.success),
        );
      }
      await _reloadAssignments();
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
          SnackBar(content: Text('${assignment.dogName} removed from $dateLabel'), backgroundColor: AppColors.success),
        );
      }
      await _reloadAssignments();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to remove: $e')));
      }
    }
  }

  Future<void> _showReassignDialog(DailyDogAssignment assignment) async {
    List<Map<String, dynamic>> staffMembers;
    Set<int> availableIds = {};
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
      return;
    }

    staffMembers.removeWhere((s) => s['id'] == assignment.staffMemberId);
    staffMembers.sort((a, b) {
      final aAvail = availableIds.isEmpty || availableIds.contains(a['id'] as int);
      final bAvail = availableIds.isEmpty || availableIds.contains(b['id'] as int);
      if (aAvail && !bAvail) return -1;
      if (!aAvail && bAvail) return 1;
      return 0;
    });

    if (!mounted) return;
    if (staffMembers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No other staff members available.')));
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
              Text('Currently assigned to ${assignment.staffMemberName}', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                decoration: const InputDecoration(labelText: 'Reassign to'),
                value: selectedStaffId,
                items: staffMembers.map((staff) {
                  final name = (staff['first_name'] != null && staff['first_name'].toString().isNotEmpty)
                      ? staff['first_name'] : staff['username'];
                  final staffId = staff['id'] as int;
                  final isAvailable = availableIds.isEmpty || availableIds.contains(staffId);
                  return DropdownMenuItem<int>(
                    value: staffId,
                    child: Row(children: [
                      Picon(PiconsDuotone.circle, size: 10, color: isAvailable ? AppColors.success : AppColors.grey400),
                      const SizedBox(width: 8),
                      Text(name.toString(), style: TextStyle(color: isAvailable ? null : AppColors.grey500)),
                      if (!isAvailable) Text(' (off)', style: TextStyle(fontSize: 11, color: AppColors.grey400)),
                    ]),
                  );
                }).toList(),
                onChanged: (value) => setDialogState(() => selectedStaffId = value),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: selectedStaffId == null ? null : () => Navigator.pop(context, true), child: const Text('Reassign')),
          ],
        ),
      ),
    );

    if (result == true && selectedStaffId != null) {
      if (!mounted) return;
      final scope = await _promptAssignmentScope(
        title: 'Reassign Scope',
        justThisDayLabel: 'Just this day',
        fromNowOnLabel: 'From now on',
      );
      if (scope == null) return;
      try {
        await _dataService.reassignDog(assignment.id, selectedStaffId!, scope: scope);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Dog reassigned successfully'), backgroundColor: AppColors.success),
          );
        }
        await _reloadAssignments();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to reassign: $e')));
        }
      }
    }
  }

  Future<void> _showTransportDialog(DailyDogAssignment assignment) async {
    // Tri-state per field: null = use dog default, true = owner, false = staff.
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
          SnackBar(content: Text('Transport updated for ${assignment.dogName}'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update transport: $e')));
      }
    }
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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

  Widget _buildSortButton() {
    return PopupMenuButton<DogSortOption>(
      icon: Picon(PiconsDuotone.sortAscending),
      tooltip: 'Sort dogs',
      onSelected: (option) {
        setState(() {
          _sortOption = option;
          _applySorting();
        });
        _cacheService.cacheSortPreference(_sortCacheKey, option.name);
      },
      itemBuilder: (context) => DogSortOption.values
          .where((option) => option != DogSortOption.custom)
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

  /// Open the full routes map for this date (loads all staff so routes/pins
  /// for everyone show, not just this staff member).
  Future<void> _openMap() async {
    setState(() => _openingMap = true);
    try {
      final assignments = await _dataService.getTodayAssignments(date: widget.date);
      final staff = await _dataService.getStaffMembers();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PickupMapScreen(
            date: widget.date,
            assignments: assignments,
            staffMembers: staff,
            canAssignDogs: widget.canAssignDogs,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to open map: $e')));
      }
    } finally {
      if (mounted) setState(() => _openingMap = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = ukDateWithDay(widget.date);
    final isUnassigned = widget.staffMemberId == null;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _dataChanged) {
          // Parent dashboard will check for this result
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isUnassigned ? 'Unassigned - $dateLabel' : "${widget.staffMemberName}'s Dogs - $dateLabel"),
          actions: [
            if (!isUnassigned)
              IconButton(
                tooltip: 'View on map',
                icon: _openingMap
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.map_outlined),
                onPressed: _openingMap ? null : _openMap,
              ),
            _buildSortButton(),
          ],
        ),
        body: _assignments.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Picon(PiconsDuotone.pawPrint, size: 64, color: Colors.grey[400]),
                    const SizedBox(height: 16),
                    Text('No dogs assigned', style: TextStyle(fontSize: 18, color: Colors.grey[600])),
                  ],
                ),
              )
            : _buildSectionedList(),
      ),
    );
  }

  Future<void> _onReorder(int oldIndex, int newIndex, List<DailyDogAssignment> staffPickups) async {
    if (oldIndex < newIndex) newIndex -= 1;
    setState(() {
      final item = staffPickups.removeAt(oldIndex);
      staffPickups.insert(newIndex, item);
      // Update local sort orders and switch to custom sort
      for (var i = 0; i < staffPickups.length; i++) {
        final idx = _assignments.indexWhere((a) => a.id == staffPickups[i].id);
        if (idx != -1) {
          _assignments[idx] = _assignments[idx].copyWith(sortOrder: i);
        }
      }
      _sortOption = DogSortOption.custom;
      _applySorting();
      _dataChanged = true;
    });
    _cacheService.cacheSortPreference(_sortCacheKey, DogSortOption.custom.name);

    // Persist to backend
    final ids = staffPickups.map((a) => a.id).toList();
    try {
      setState(() => _reordering = true);
      await _dataService.reorderAssignments(ids);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save order: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _reordering = false);
    }
  }

  Widget _buildSectionedList() {
    // Reorderable when staff handle at least one leg (pickup or drop-off) — this
    // includes "client drops off, staff takes home" and vice versa. Only dogs
    // the owner both brings AND collects (no staff transport) sit in the locked
    // section, since they need no route position.
    bool ownerHandlesBoth(DailyDogAssignment a) => a.effectiveOwnerBrings && a.effectiveOwnerCollects;
    final staffPickups = _assignments.where((a) => !ownerHandlesBoth(a)).toList();
    final ownerDropoffs = _assignments.where(ownerHandlesBoth).toList();

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        // Saving indicator
        if (_reordering)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: LinearProgressIndicator(),
            ),
          ),
        // Reorderable staff pickups section
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverReorderableList(
            itemCount: staffPickups.length,
            onReorder: (oldIndex, newIndex) => _onReorder(oldIndex, newIndex, staffPickups),
            itemBuilder: (context, index) {
              final a = staffPickups[index];
              return _buildAssignmentCard(a, key: ValueKey(a.id), reorderIndex: index);
            },
          ),
        ),
        // Owner drop-offs section (not reorderable)
        if (ownerDropoffs.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Picon(PiconsDuotone.houseLine, size: 18, color: Colors.teal),
                  const SizedBox(width: 8),
                  Text('Owner brings & collects',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Text('${ownerDropoffs.length}', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildAssignmentCard(ownerDropoffs[index], key: ValueKey(ownerDropoffs[index].id)),
                childCount: ownerDropoffs.length,
              ),
            ),
          ),
        ],
        // Bottom padding when no owner drop-offs
        if (ownerDropoffs.isEmpty)
          const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }

  Widget _buildAssignmentCard(DailyDogAssignment assignment, {Key? key, int? reorderIndex}) {
    final next = _nextStatus(assignment.status);
    final previous = _previousStatus(assignment.status);
    final statusColor = _statusColor(assignment.status);

    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openQuickInfo(assignment),
        child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Dog info row
            Row(
              children: [
                // Drag handle — only shown for reorderable items
                if (reorderIndex != null)
                  ReorderableDragStartListener(
                    index: reorderIndex,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Picon(
                        PiconsDuotone.dotsSixVertical,
                        size: 24,
                        color: Colors.grey[400],
                      ),
                    ),
                  ),
                if (assignment.dogProfileImage != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: CachedNetworkImage(
                      imageUrl: assignment.dogProfileImage!,
                      width: 48, height: 48, fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: 48, height: 48, color: Colors.grey[200],
                        child: Picon(PiconsDuotone.pawPrint),
                      ),
                      errorWidget: (context, url, error) =>
                          CircleAvatar(radius: 24, child: Picon(PiconsDuotone.pawPrint)),
                    ),
                  )
                else
                  CircleAvatar(radius: 24, child: Picon(PiconsDuotone.pawPrint)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(assignment.dogName,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                      Text('Owner: ${assignment.ownerName}', style: Theme.of(context).textTheme.bodySmall),
                      if (assignment.isBoarding)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(children: [
                            Picon(PiconsDuotone.house, size: 14, color: Colors.deepPurple),
                            const SizedBox(width: 4),
                            Text('Boarding – No pickup needed',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.deepPurple, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      if (widget.canAssignDogs)
                        Text('Staff: ${assignment.staffMemberName}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.primary)),
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
                    } else if (value == 'remove_from_day') {
                      _confirmRemoveFromDay(assignment);
                    } else if (value == 'transport') {
                      _showTransportDialog(assignment);
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
                    avatar: Picon(_statusIcon(assignment.status), size: 18, color: statusColor),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(assignment.status.displayName, style: TextStyle(color: statusColor, fontSize: 12)),
                        Picon(PiconsDuotone.caretDown, size: 16, color: statusColor),
                      ],
                    ),
                    backgroundColor: statusColor.withValues(alpha: 0.1),
                    side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Transport indicator (owner brings / collects)
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
            // Pickup info
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
      ),
    );
  }
}
