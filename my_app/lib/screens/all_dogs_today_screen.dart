import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
import '../models/daily_dog_assignment.dart';
import '../services/data_service.dart';
import '../utils/date_formats.dart';

enum _SortOption {
  nameAsc('Name (A-Z)'),
  nameDesc('Name (Z-A)'),
  staffMember('Staff Member'),
  status('Status');

  final String label;
  const _SortOption(this.label);
}

/// Shows all dogs for a given date in a single flat list.
/// Accessible to all staff from the dashboard overview.
class AllDogsTodayScreen extends StatefulWidget {
  final DateTime date;
  final List<DailyDogAssignment> assignments;

  const AllDogsTodayScreen({
    super.key,
    required this.date,
    required this.assignments,
  });

  @override
  State<AllDogsTodayScreen> createState() => _AllDogsTodayScreenState();
}

class _AllDogsTodayScreenState extends State<AllDogsTodayScreen> {
  final DataService _dataService = ApiDataService();
  late List<DailyDogAssignment> _assignments;
  _SortOption _sortOption = _SortOption.nameAsc;
  bool _dataChanged = false;
  String _searchQuery = '';
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    _assignments = List.of(widget.assignments);
    _applySorting();
  }

  void _applySorting() {
    switch (_sortOption) {
      case _SortOption.nameAsc:
        _assignments.sort((a, b) => a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase()));
      case _SortOption.nameDesc:
        _assignments.sort((a, b) => b.dogName.toLowerCase().compareTo(a.dogName.toLowerCase()));
      case _SortOption.staffMember:
        _assignments.sort((a, b) {
          final cmp = a.staffMemberName.toLowerCase().compareTo(b.staffMemberName.toLowerCase());
          if (cmp != 0) return cmp;
          return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
        });
      case _SortOption.status:
        _assignments.sort((a, b) {
          final cmp = a.status.index.compareTo(b.status.index);
          if (cmp != 0) return cmp;
          return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
        });
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

  Future<void> _reloadAssignments() async {
    try {
      final all = await _dataService.getTodayAssignments(date: widget.date);
      if (mounted) {
        setState(() {
          _assignments = all;
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
      case AssignmentStatus.pickedUp: return AssignmentStatus.atDaycare;
      case AssignmentStatus.atDaycare: return AssignmentStatus.droppedOff;
      case AssignmentStatus.droppedOff: return null;
    }
  }

  AssignmentStatus? _previousStatus(AssignmentStatus current) {
    switch (current) {
      case AssignmentStatus.assigned: return null;
      case AssignmentStatus.pickedUp: return AssignmentStatus.assigned;
      case AssignmentStatus.atDaycare: return AssignmentStatus.pickedUp;
      case AssignmentStatus.droppedOff: return AssignmentStatus.atDaycare;
    }
  }

  PhosphorIconData _statusIcon(AssignmentStatus status) {
    switch (status) {
      case AssignmentStatus.assigned: return PhosphorIconsDuotone.clipboardText;
      case AssignmentStatus.pickedUp: return PhosphorIconsDuotone.car;
      case AssignmentStatus.atDaycare: return PhosphorIconsDuotone.house;
      case AssignmentStatus.droppedOff: return PhosphorIconsFill.checkCircle;
    }
  }

  Color _statusColor(AssignmentStatus status) {
    switch (status) {
      case AssignmentStatus.assigned: return Colors.orange;
      case AssignmentStatus.pickedUp: return AppColors.primary;
      case AssignmentStatus.atDaycare: return AppColors.primaryLight;
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
                PhosphorIcon(PhosphorIconsDuotone.info),
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

  // ─── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final dateLabel = ukDateWithDay(widget.date);
    final filtered = _filteredAssignments;

    // Status summary counts
    final assignedCount = _assignments.where((a) => a.status == AssignmentStatus.assigned).length;
    final pickedUpCount = _assignments.where((a) => a.status == AssignmentStatus.pickedUp).length;
    final atDaycareCount = _assignments.where((a) => a.status == AssignmentStatus.atDaycare).length;
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
              icon: PhosphorIcon(_showSearch ? PhosphorIconsDuotone.x : PhosphorIconsDuotone.magnifyingGlass),
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
                  _buildStatusChip('Picked Up', pickedUpCount, AppColors.primary),
                  const SizedBox(width: 8),
                  _buildStatusChip('At Daycare', atDaycareCount, AppColors.primaryLight),
                  const SizedBox(width: 8),
                  _buildStatusChip('Done', droppedOffCount, Colors.green),
                ],
              ),
            ),
            // Dog list
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          PhosphorIcon(PhosphorIconsDuotone.pawPrint, size: 64, color: Colors.grey[400]),
                          const SizedBox(height: 16),
                          Text(
                            _searchQuery.isNotEmpty ? 'No dogs match your search' : 'No dogs for this date',
                            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _reloadAssignments,
                      child: _sortOption == _SortOption.staffMember
                          ? _buildGroupedByStaffList(filtered)
                          : _buildFlatList(filtered),
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
      icon: PhosphorIcon(PhosphorIconsDuotone.sortAscending),
      tooltip: 'Sort dogs',
      onSelected: (option) => setState(() {
        _sortOption = option;
        _applySorting();
      }),
      itemBuilder: (context) => _SortOption.values
          .map((option) => PopupMenuItem(
                value: option,
                child: Row(children: [
                  if (_sortOption == option) PhosphorIcon(PhosphorIconsDuotone.check, size: 18) else const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Text(option.label),
                ]),
              ))
          .toList(),
    );
  }

  Widget _buildFlatList(List<DailyDogAssignment> assignments) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: assignments.length,
      itemBuilder: (context, i) => _buildAssignmentCard(assignments[i]),
    );
  }

  Widget _buildGroupedByStaffList(List<DailyDogAssignment> assignments) {
    // Group by staff member
    final Map<int, List<DailyDogAssignment>> groups = {};
    final Map<int, String> staffNames = {};
    for (final a in assignments) {
      groups.putIfAbsent(a.staffMemberId, () => []).add(a);
      staffNames[a.staffMemberId] = a.staffMemberName;
    }
    final sortedStaffIds = groups.keys.toList()
      ..sort((a, b) => staffNames[a]!.toLowerCase().compareTo(staffNames[b]!.toLowerCase()));

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: sortedStaffIds.length,
      itemBuilder: (context, i) {
        final staffId = sortedStaffIds[i];
        final staffAssignments = groups[staffId]!;
        final staffName = staffNames[staffId]!;
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
            ...staffAssignments.map((a) => _buildAssignmentCard(a)),
          ],
        );
      },
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
                        child: PhosphorIcon(PhosphorIconsDuotone.pawPrint),
                      ),
                      errorWidget: (context, url, error) =>
                          CircleAvatar(radius: 22, child: PhosphorIcon(PhosphorIconsDuotone.pawPrint)),
                    ),
                  )
                else
                  CircleAvatar(radius: 22, child: PhosphorIcon(PhosphorIconsDuotone.pawPrint)),
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
                            PhosphorIcon(PhosphorIconsDuotone.house, size: 14, color: Colors.deepPurple),
                            const SizedBox(width: 4),
                            Text('Boarding',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.deepPurple, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                    ],
                  ),
                ),
                // Status chip with actions
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'next' && next != null) {
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
                          PhosphorIcon(_statusIcon(next), size: 18),
                          const SizedBox(width: 8),
                          Text('Mark ${next.displayName}'),
                        ]),
                      ),
                    if (previous != null)
                      PopupMenuItem(
                        value: 'previous',
                        child: Row(children: [
                          PhosphorIcon(_statusIcon(previous), size: 18),
                          const SizedBox(width: 8),
                          Text('Revert to ${previous.displayName}'),
                        ]),
                      ),
                  ],
                  child: Chip(
                    avatar: PhosphorIcon(_statusIcon(assignment.status), size: 16, color: statusColor),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(assignment.status.displayName, style: TextStyle(color: statusColor, fontSize: 11)),
                        PhosphorIcon(PhosphorIconsDuotone.caretDown, size: 14, color: statusColor),
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
                          const PhosphorIcon(PhosphorIconsDuotone.houseLine, size: 14, color: Colors.teal),
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
                          const PhosphorIcon(PhosphorIconsDuotone.houseLine, size: 14, color: Colors.indigo),
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
                    PhosphorIcon(PhosphorIconsDuotone.mapPin, size: 16, color: Theme.of(context).colorScheme.primary),
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
                    PhosphorIcon(PhosphorIconsDuotone.phone, size: 16, color: Theme.of(context).colorScheme.primary),
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
                    PhosphorIcon(PhosphorIconsDuotone.info, size: 16, color: Theme.of(context).colorScheme.primary),
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
