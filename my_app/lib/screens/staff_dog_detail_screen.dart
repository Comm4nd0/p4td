import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
import '../constants/pickup_map.dart';
import '../models/daily_dog_assignment.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../services/cache_service.dart';
import '../utils/date_formats.dart';
import '../widgets/assignment_action_dialogs.dart';
import '../widgets/assignment_card.dart';
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

  /// Full staff list (from /staff_members/) so this member's identity colour
  /// resolves the same way as on the dashboard and map. Optional — falls back
  /// to the automatic palette when empty.
  final List<Map<String, dynamic>> staffMembers;

  const StaffDogDetailScreen({
    super.key,
    required this.staffMemberId,
    required this.staffMemberName,
    required this.date,
    required this.assignments,
    required this.canAssignDogs,
    this.staffMembers = const [],
  });

  @override
  State<StaffDogDetailScreen> createState() => _StaffDogDetailScreenState();
}

class _StaffDogDetailScreenState extends State<StaffDogDetailScreen> {
  static const _sortCacheKey = 'staff_dog_detail';
  final DataService _dataService = getIt<DataService>();
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

    final scope = await promptAssignmentScope(
      context,
      title: 'Unassign Scope',
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
    final selectedStaffId = await pickStaffMember(
      context,
      title: 'Reassign ${assignment.dogName}',
      subtitle: 'Currently assigned to ${assignment.staffMemberName}',
      confirmLabel: 'Reassign',
      dropdownLabel: 'Reassign to',
      emptyMessage: 'No other staff members available.',
      currentStaffId: assignment.staffMemberId,
      initialStaffMembers: const [],
      initialAvailableStaffIds: const {},
      loadStaff: _dataService.getStaffMembers,
      loadAvailableIds: () => _dataService.getAvailableStaffForDate(widget.date),
    );
    if (selectedStaffId == null || !mounted) return;

    final scope = await promptAssignmentScope(
      context,
      title: 'Reassign Scope',
    );
    if (scope == null) return;
    try {
      await _dataService.reassignDog(assignment.id, selectedStaffId, scope: scope);
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

  Future<void> _showTransportDialog(DailyDogAssignment assignment) async {
    final edit = await showTransportDialog(context, assignment);
    if (edit == null || !mounted) return;

    try {
      final updated = await _dataService.setAssignmentTransport(
        assignment.id,
        ownerBrings: edit.brings,
        ownerCollects: edit.collects,
        ownerBringsTime: edit.resolvedBringsTime,
        ownerCollectsTime: edit.resolvedCollectsTime,
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
    return AssignmentCard(
      key: key,
      assignment: assignment,
      canAssignDogs: widget.canAssignDogs,
      staffColor: widget.staffMemberId != null
          ? StaffColorResolver(widget.staffMembers).of(widget.staffMemberId!)
          : null,
      pickupNumber: pickupRunNumbers(_assignments)[assignment.id],
      onTap: () => _openQuickInfo(assignment),
      onUpdateStatus: (newStatus) => _updateStatus(assignment, newStatus),
      onTransport: () => _showTransportDialog(assignment),
      onReassign: () => _showReassignDialog(assignment),
      onUnassign: () => _confirmUnassign(assignment),
      onRemoveFromDay: () => _confirmRemoveFromDay(assignment),
      onOpenMaps: _openMaps,
      onCallPhone: _callPhone,
      onShowPickupInstructions: () => _showPickupInstructions(assignment),
      formatTime: _formatTime,
      // Drift values for this screen.
      reorderIndex: reorderIndex,
      bottomMargin: 12,
      avatarRadius: 24,
      cacheAvatar: false,
      showStaffLine: widget.canAssignDogs,
      staffLineAfterBoarding: true,
      boardingLabel: 'Boarding – No pickup needed',
      rowSpacing: 8,
      statusIconSize: 18,
      statusFontSize: 12,
      statusCaretSize: 16,
      statusChipCompact: false,
    );
  }
}
