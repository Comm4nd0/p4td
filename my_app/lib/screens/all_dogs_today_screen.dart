import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
import '../constants/pickup_map.dart';
import '../models/daily_dog_assignment.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../services/cache_service.dart';
import '../utils/date_formats.dart';
import '../widgets/assignment_action_dialogs.dart';
import '../widgets/assignment_card.dart';
import '../widgets/dog_quick_info_sheet.dart';
import 'dog_home_screen.dart';

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
  final DataService _dataService = getIt<DataService>();
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

  /// Single tap on a dog card: quick-info sheet, with optional follow-on
  /// navigation to the full profile.
  Future<void> _openQuickInfo({Dog? dog, DailyDogAssignment? assignment}) async {
    final fullDog = await DogQuickInfoSheet.show(context, dog: dog, assignment: assignment);
    if (fullDog == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DogHomeScreen(dog: fullDog, isStaff: true)),
    );
    if (mounted) _reloadAll();
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
          SnackBar(content: Text('${assignment.dogName} removed from $dateLabel'), backgroundColor: AppColors.success),
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

    final scope = await promptAssignmentScope(
      context,
      title: 'Reassign Scope',
    );
    if (scope == null) return;
    try {
      await _dataService.reassignDog(assignment.id, picked, scope: scope);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dog reassigned successfully'), backgroundColor: AppColors.success),
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

  // ─── Unassigned-card actions ──────────────────────────────────────

  Future<int?> _pickStaffMember({
    required String title,
    int? currentStaffId,
    String? subtitle,
    String confirmLabel = 'Assign',
  }) {
    return pickStaffMember(
      context,
      title: title,
      currentStaffId: currentStaffId,
      subtitle: subtitle,
      confirmLabel: confirmLabel,
      initialStaffMembers: widget.staffMembers,
      initialAvailableStaffIds: widget.availableStaffIds,
      loadStaff: _dataService.getStaffMembers,
      loadAvailableIds: () => _dataService.getAvailableStaffForDate(widget.date),
    );
  }

  Future<void> _assignToMe(Dog dog) async {
    try {
      final result = await _dataService.assignDogsToMe([int.parse(dog.id)], date: widget.date);
      if (mounted) {
        if (result.hasSkipped) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name}: ${result.skipped.first.reason}'), backgroundColor: AppColors.warning),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name} assigned to you'), backgroundColor: AppColors.success),
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
            SnackBar(content: Text('${dog.name}: ${result.skipped.first.reason}'), backgroundColor: AppColors.warning),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name} assigned'), backgroundColor: AppColors.success),
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
          SnackBar(content: Text('${dog.name} removed from $dateLabel'), backgroundColor: AppColors.success),
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
                  : RefreshIndicator.adaptive(
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

  // Only dogs with no staff transport today sit in the separate locked
  // section — the owner brings AND collects them, or they're boarding on a
  // non-travel day (already with staff). Dogs with at least one staff leg
  // belong in the main route list (matches staff_dog_detail_screen.dart).

  Widget _buildFlatList(List<DailyDogAssignment> assignments, List<Dog> unassigned) {
    final staffPickups = assignments.where((a) => !a.noStaffTransport).toList();
    final ownerDropoffs = assignments.where((a) => a.noStaffTransport).toList();

    // Build a flat list of lazy row builders so only visible rows are built.
    final rows = <Widget Function(BuildContext)>[];
    if (unassigned.isNotEmpty) {
      rows.add((_) => _buildUnassignedSectionHeader(unassigned.length));
      for (final d in unassigned) {
        rows.add((_) => _buildUnassignedCard(d));
      }
      rows.add((_) => const SizedBox(height: 12));
    }
    for (final a in staffPickups) {
      rows.add((_) => _buildAssignmentCard(a));
    }
    if (ownerDropoffs.isNotEmpty) {
      rows.add((ctx) => Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Row(
              children: [
                Picon(PiconsDuotone.houseLine, size: 18, color: Colors.teal),
                const SizedBox(width: 8),
                Text('No staff transport today',
                    style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text('${ownerDropoffs.length}', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              ],
            ),
          ));
      for (final a in ownerDropoffs) {
        rows.add((_) => _buildAssignmentCard(a));
      }
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index](context),
    );
  }

  /// Same colour resolution as the map and dashboard (honours each member's
  /// chosen colour), so the grouped headers match their pins.
  StaffColorResolver get _staffColors => StaffColorResolver(widget.staffMembers);

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

    // Flatten into lazy row builders so only visible rows are built.
    final rows = <Widget Function(BuildContext)>[];
    if (unassigned.isNotEmpty) {
      rows.add((_) => _buildUnassignedSectionHeader(unassigned.length));
      for (final d in unassigned) {
        rows.add((_) => _buildUnassignedCard(d));
      }
      rows.add((_) => const SizedBox(height: 12));
    }
    for (var i = 0; i < sortedStaffIds.length; i++) {
      final staffId = sortedStaffIds[i];
      final staffAssignments = groups[staffId]!;
      final staffName = staffNames[staffId]!;
      final staffPickups = staffAssignments.where((a) => !a.noStaffTransport).toList();
      final ownerDropoffs = staffAssignments.where((a) => a.noStaffTransport).toList();
      final isFirst = i == 0;
      rows.add((ctx) => Padding(
            padding: EdgeInsets.only(top: isFirst ? 0 : 12, bottom: 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: _staffColors.of(staffId),
                  child: Text(staffName[0], style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Text(staffName,
                    style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text('${staffAssignments.length} dog${staffAssignments.length == 1 ? '' : 's'}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              ],
            ),
          ));
      for (final a in staffPickups) {
        rows.add((_) => _buildAssignmentCard(a));
      }
      if (ownerDropoffs.isNotEmpty) {
        rows.add((ctx) => Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6, left: 4),
              child: Row(
                children: [
                  Picon(PiconsDuotone.houseLine, size: 16, color: Colors.teal),
                  const SizedBox(width: 6),
                  Text('No staff transport today',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: Colors.teal)),
                ],
              ),
            ));
        for (final a in ownerDropoffs) {
          rows.add((_) => _buildAssignmentCard(a));
        }
      }
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index](context),
    );
  }

  Widget _buildUnassignedCard(Dog dog) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.red.shade200, width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openQuickInfo(dog: dog),
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
                  memCacheWidth: (44 * MediaQuery.of(context).devicePixelRatio).round(),
                  memCacheHeight: (44 * MediaQuery.of(context).devicePixelRatio).round(),
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
      ),
    );
  }

  /// Pickup-run numbers for the whole day (unfiltered), so badges stay stable
  /// while searching/filtering.
  Map<int, int> get _pickupNumbers => pickupRunNumbers(_assignments);

  Widget _buildAssignmentCard(DailyDogAssignment assignment) {
    return AssignmentCard(
      assignment: assignment,
      canAssignDogs: widget.canAssignDogs,
      staffColor: _staffColors.of(assignment.staffMemberId),
      pickupNumber: _pickupNumbers[assignment.id],
      onTap: () => _openQuickInfo(assignment: assignment),
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
      bottomMargin: 8,
      avatarRadius: 22,
      cacheAvatar: true,
      showStaffLine: _sortOption != _SortOption.staffMember,
      staffLineAfterBoarding: false,
      boardingLabel: assignment.boardingLabel,
      rowSpacing: 6,
      statusIconSize: 16,
      statusFontSize: 11,
      statusCaretSize: 14,
      statusChipCompact: true,
    );
  }
}
