import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../constants/app_colors.dart';
import '../constants/pickup_map.dart';
import '../models/daily_dog_assignment.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/dog_quick_info_sheet.dart';

/// What gets dragged around the board: an existing assignment, or an
/// unassigned rostered dog.
class _DragItem {
  final DailyDogAssignment? assignment;
  final Dog? dog;
  _DragItem.assignment(this.assignment) : dog = null;
  _DragItem.dog(this.dog) : assignment = null;

  String get dogName => assignment?.dogName ?? dog!.name;
  String? get imageUrl => assignment?.dogProfileImage ?? dog!.profileImageUrl;
}

/// Remembers which columns the user has manually shown/hidden so the choice
/// survives leaving the board and coming back within an app session (the
/// screen is pushed fresh each time). In-memory only — resets on app restart.
class _BoardFilterPrefs {
  static Map<int, bool>? columnOverrides;
  static bool? showUnassigned;
}

/// The whole day on one screen: a colour-coded column per staff member (plus
/// Unassigned first), each dog as a compact card with its photo, pickup-run
/// number and status tick.
///
/// Long-press-drag a dog onto another column to reassign it (or in/out of
/// Unassigned to assign/unassign), or onto another dog in the SAME column to
/// change the pickup order. Reordering is open to all staff (same as the staff
/// dog list); moving dogs between staff requires [canAssignDogs].
class DayBoardScreen extends StatefulWidget {
  final DateTime date;
  final List<DailyDogAssignment> assignments;
  final List<Dog> unassignedDogs;
  final List<Map<String, dynamic>> staffMembers;
  final Set<int> availableStaffIds;
  final bool canAssignDogs;

  const DayBoardScreen({
    super.key,
    required this.date,
    required this.assignments,
    this.unassignedDogs = const [],
    this.staffMembers = const [],
    this.availableStaffIds = const {},
    this.canAssignDogs = false,
  });

  @override
  State<DayBoardScreen> createState() => _DayBoardScreenState();
}

class _DayBoardScreenState extends State<DayBoardScreen> {
  final DataService _dataService = getIt<DataService>();

  late List<DailyDogAssignment> _assignments;
  late List<Dog> _unassignedDogs;
  late final StaffColorResolver _staffColors;
  bool _busy = false;
  bool _dataChanged = false;

  /// Manual show/hide choices per staff column; anyone not in the map follows
  /// the default (working staff shown, off staff hidden unless they have dogs).
  final Map<int, bool> _columnOverrides = {};
  bool _showUnassigned = true;

  @override
  void initState() {
    super.initState();
    _assignments = List.of(widget.assignments);
    _unassignedDogs = List.of(widget.unassignedDogs);
    _staffColors = StaffColorResolver(widget.staffMembers);
    _columnOverrides.addAll(_BoardFilterPrefs.columnOverrides ?? {});
    _showUnassigned = _BoardFilterPrefs.showUnassigned ?? true;
  }

  @override
  void dispose() {
    _BoardFilterPrefs.columnOverrides = Map.of(_columnOverrides);
    _BoardFilterPrefs.showUnassigned = _showUnassigned;
    super.dispose();
  }

  /// Whether a staff member is on the rota for this date. An empty
  /// availability set means availability is unknown — treat everyone as
  /// working rather than hiding the whole board.
  bool _isWorking(int staffId) =>
      widget.availableStaffIds.isEmpty || widget.availableStaffIds.contains(staffId);

  /// Default column visibility: staff who are working that day, or who have
  /// dogs assigned anyway (an off member with dogs is a problem worth seeing).
  bool _defaultVisible(int staffId) =>
      _isWorking(staffId) || _assignments.any((a) => a.staffMemberId == staffId);

  bool _isColumnVisible(int staffId) =>
      _columnOverrides[staffId] ?? _defaultVisible(staffId);

  Future<void> _reload() async {
    try {
      final results = await Future.wait([
        _dataService.getTodayAssignments(date: widget.date),
        _dataService.getUnassignedDogs(date: widget.date),
      ]);
      if (!mounted) return;
      setState(() {
        _assignments = results[0] as List<DailyDogAssignment>;
        _unassignedDogs = results[1] as List<Dog>;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to refresh: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  void _error(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  // ---- Column data ----

  /// Staff columns: everyone from the staff list (so a member with no dogs yet
  /// is still a drop target), plus anyone with assignments who isn't in it.
  /// Sorted by name.
  List<({int id, String name})> get _staffColumns {
    final byId = <int, String>{};
    for (final s in widget.staffMembers) {
      final name = (s['first_name'] as String?)?.isNotEmpty == true
          ? s['first_name'] as String
          : s['username'] as String? ?? '?';
      byId[s['id'] as int] = name;
    }
    for (final a in _assignments) {
      byId.putIfAbsent(a.staffMemberId, () => a.staffMemberName);
    }
    final columns = byId.entries.map((e) => (id: e.key, name: e.value)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return columns;
  }

  /// A staff member's dogs in pickup-run order (sortOrder, then name), with
  /// owner-handles-both dogs at the end (they have no run position).
  List<DailyDogAssignment> _dogsFor(int staffId) {
    final run = <DailyDogAssignment>[];
    final ownerHandled = <DailyDogAssignment>[];
    for (final a in _assignments.where((a) => a.staffMemberId == staffId)) {
      (a.effectiveOwnerBrings && a.effectiveOwnerCollects ? ownerHandled : run).add(a);
    }
    int byRun(DailyDogAssignment a, DailyDogAssignment b) {
      final cmp = a.sortOrder.compareTo(b.sortOrder);
      if (cmp != 0) return cmp;
      return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
    }
    run.sort(byRun);
    ownerHandled.sort((a, b) => a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase()));
    return [...run, ...ownerHandled];
  }

  Map<int, int> get _pickupNumbers => pickupRunNumbers(_assignments);

  // ---- Drop handling ----

  Future<void> _guarded(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      _dataChanged = true;
    } catch (e) {
      if (mounted) _error('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Drop onto a staff column (append) or onto a card in it (insert there).
  Future<void> _dropOnStaff(_DragItem item, int staffId, {DailyDogAssignment? before}) async {
    final assignment = item.assignment;
    if (assignment == null) {
      // Unassigned dog → assign to this staff member.
      await _guarded(() async {
        await _dataService.assignDogs([item.dog!.id].map(int.parse).toList(), staffId,
            date: widget.date);
        await _reload();
      });
      return;
    }
    if (assignment.staffMemberId == staffId) {
      // Same column → reorder the pickup run.
      if (before == null || before.id == assignment.id) return;
      await _guarded(() async {
        final run = _dogsFor(staffId)
            .where((a) => !(a.effectiveOwnerBrings && a.effectiveOwnerCollects))
            .toList();
        final ids = run.map((a) => a.id).toList()..remove(assignment.id);
        final targetIndex = ids.indexOf(before.id);
        ids.insert(targetIndex < 0 ? ids.length : targetIndex, assignment.id);
        await _dataService.reorderAssignments(ids);
        // Reflect the new order locally without waiting for a full reload.
        setState(() {
          for (final a in _assignments) {
            final position = ids.indexOf(a.id);
            if (position >= 0) {
              _assignments[_assignments.indexOf(a)] = a.copyWith(sortOrder: position);
            }
          }
        });
      });
      return;
    }
    // Different column → reassign.
    await _guarded(() async {
      await _dataService.reassignDog(assignment.id, staffId);
      await _reload();
    });
  }

  Future<void> _dropOnUnassigned(_DragItem item) async {
    final assignment = item.assignment;
    if (assignment == null) return; // already unassigned
    await _guarded(() async {
      await _dataService.unassignDog(assignment.id);
      await _reload();
    });
  }

  /// Whether [item] may be dropped on [staffId] (null = the Unassigned column).
  bool _canDrop(_DragItem item, int? staffId) {
    if (_busy) return false;
    final assignment = item.assignment;
    if (assignment != null && staffId == assignment.staffMemberId) {
      return true; // reorder within own column — open to all staff
    }
    return widget.canAssignDogs;
  }

  /// Bottom sheet with a switch per column. Staff not working that day are
  /// labelled "(off)" and start hidden; flipping a switch overrides the
  /// default for the rest of the session.
  void _showColumnFilter() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          void update(void Function() change) {
            setSheetState(change);
            setState(() {});
          }

          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('Show columns',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                SwitchListTile.adaptive(
                  dense: true,
                  title: const Text('Unassigned'),
                  secondary: const CircleAvatar(
                    radius: 10,
                    backgroundColor: kUnassignedColor,
                  ),
                  value: _showUnassigned,
                  onChanged: (v) => update(() => _showUnassigned = v),
                ),
                for (final staff in _staffColumns)
                  SwitchListTile.adaptive(
                    dense: true,
                    title: Text(_isWorking(staff.id) ? staff.name : '${staff.name} (off)'),
                    secondary: CircleAvatar(
                      radius: 10,
                      backgroundColor: _staffColors.of(staff.id),
                    ),
                    value: _isColumnVisible(staff.id),
                    onChanged: (v) => update(() => _columnOverrides[staff.id] = v),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final columns = _staffColumns.where((s) => _isColumnVisible(s.id)).toList();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.pop(context, _dataChanged);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            children: [
              const Text('Day Board'),
              Text(ukDateWithDay(widget.date),
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.filter_list),
              tooltip: 'Show/hide columns',
              onPressed: _showColumnFilter,
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
          ],
        ),
        body: (!_showUnassigned && columns.isEmpty)
            ? Center(
                child: Text('All columns hidden — use the filter to show them.',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              )
            : ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(12),
                children: [
                  if (_showUnassigned)
                    _buildColumn(
                      staffId: null,
                      name: 'Unassigned',
                      color: kUnassignedColor,
                      dogs: const [],
                      unassigned: _unassignedDogs,
                    ),
                  for (final staff in columns)
                    _buildColumn(
                      staffId: staff.id,
                      name: staff.name,
                      color: _staffColors.of(staff.id),
                      dogs: _dogsFor(staff.id),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildColumn({
    required int? staffId,
    required String name,
    required Color color,
    required List<DailyDogAssignment> dogs,
    List<Dog> unassigned = const [],
  }) {
    final isOff = staffId != null && !_isWorking(staffId);

    // Leg-aware collected progress, matching the dashboard staff cards.
    final pickupLeg = dogs.where((a) => !a.effectiveOwnerBrings).toList();
    final collected = pickupLeg
        .where((a) =>
            a.status == AssignmentStatus.pickedUp || a.status == AssignmentStatus.droppedOff)
        .length;

    return DragTarget<_DragItem>(
      onWillAcceptWithDetails: (details) => _canDrop(details.data, staffId),
      onAcceptWithDetails: (details) => staffId == null
          ? _dropOnUnassigned(details.data)
          : _dropOnStaff(details.data, staffId),
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty;
        final count = staffId == null ? unassigned.length : dogs.length;
        return Container(
          width: 260,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: highlighted ? color : color.withValues(alpha: 0.35),
              width: highlighted ? 2.5 : 1.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: color,
                      child: staffId == null
                          ? const Icon(Icons.person_off_outlined, color: Colors.white, size: 16)
                          : Text(name[0],
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isOff ? '$name (off)' : name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$count',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              if (staffId != null && pickupLeg.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$collected of ${pickupLeg.length} collected',
                          style: TextStyle(
                              fontSize: 11,
                              color: collected == pickupLeg.length
                                  ? AppColors.success
                                  : Theme.of(context).colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: pickupLeg.isEmpty ? 0 : collected / pickupLeg.length,
                          minHeight: 5,
                          color: color,
                          backgroundColor: color.withValues(alpha: 0.15),
                        ),
                      ),
                    ],
                  ),
                ),
              // Dogs
              Expanded(
                child: (staffId == null ? unassigned.isEmpty : dogs.isEmpty)
                    ? Center(
                        child: Text(
                          staffId == null ? 'No unassigned dogs' : 'Drop dogs here',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.all(8),
                        children: staffId == null
                            ? [for (final d in unassigned) _buildUnassignedRow(d)]
                            : [for (final a in dogs) _buildDogRow(a, staffId)],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDogRow(DailyDogAssignment a, int staffId) {
    final row = _DogRow(
      key: ValueKey('a${a.id}'),
      name: a.dogName,
      imageUrl: a.dogProfileImage,
      number: _pickupNumbers[a.id],
      color: _staffColors.of(staffId),
      status: a.status,
      ownerBrings: a.effectiveOwnerBrings,
      ownerCollects: a.effectiveOwnerCollects,
      isBoarding: a.isBoarding,
      onTap: () => DogQuickInfoSheet.show(context, assignment: a),
    );
    final item = _DragItem.assignment(a);
    // Each row is also a drop target so a same-column drop can set the exact
    // position on the pickup run.
    return DragTarget<_DragItem>(
      onWillAcceptWithDetails: (details) =>
          details.data.assignment?.id != a.id && _canDrop(details.data, staffId),
      onAcceptWithDetails: (details) => _dropOnStaff(details.data, staffId, before: a),
      builder: (context, candidates, rejected) => Container(
        decoration: candidates.isNotEmpty
            ? BoxDecoration(
                border: Border(top: BorderSide(color: _staffColors.of(staffId), width: 3)))
            : null,
        child: _draggable(item, row),
      ),
    );
  }

  Widget _buildUnassignedRow(Dog d) {
    final row = _DogRow(
      key: ValueKey('d${d.id}'),
      name: d.name,
      imageUrl: d.profileImageUrl,
      number: null,
      color: kUnassignedColor,
      status: null,
      onTap: () => DogQuickInfoSheet.show(context, dog: d),
    );
    return _draggable(_DragItem.dog(d), row);
  }

  Widget _draggable(_DragItem item, Widget row) {
    return LongPressDraggable<_DragItem>(
      data: item,
      maxSimultaneousDrags: _busy ? 0 : 1,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: 236,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
          ),
          child: Text(item.dogName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: row),
      child: row,
    );
  }
}

/// One compact dog card on the board: photo (with run-number badge), name,
/// transport/boarding hints and a status tick.
class _DogRow extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final int? number;
  final Color color;
  final AssignmentStatus? status;
  final bool ownerBrings;
  final bool ownerCollects;
  final bool isBoarding;
  final VoidCallback onTap;

  const _DogRow({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.number,
    required this.color,
    required this.status,
    this.ownerBrings = false,
    this.ownerCollects = false,
    this.isBoarding = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  imageUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: CachedNetworkImage(
                            imageUrl: imageUrl!,
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                            memCacheWidth:
                                (36 * MediaQuery.of(context).devicePixelRatio).round(),
                            memCacheHeight:
                                (36 * MediaQuery.of(context).devicePixelRatio).round(),
                            placeholder: (context, url) => Container(
                                width: 36,
                                height: 36,
                                color: Colors.grey[200],
                                child: Picon(PiconsDuotone.pawPrint, size: 18)),
                            errorWidget: (context, url, error) => CircleAvatar(
                                radius: 18, child: Picon(PiconsDuotone.pawPrint, size: 18)),
                          ),
                        )
                      : CircleAvatar(radius: 18, child: Picon(PiconsDuotone.pawPrint, size: 18)),
                  if (number != null)
                    Positioned(
                      left: -5,
                      top: -5,
                      child: Container(
                        width: 17,
                        height: 17,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Text('$number',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    if (ownerBrings || ownerCollects || isBoarding)
                      Row(children: [
                        if (isBoarding) ...[
                          Picon(PiconsDuotone.bed, size: 12, color: Colors.deepPurple),
                          const SizedBox(width: 2),
                          const Text('Boarding',
                              style: TextStyle(fontSize: 10, color: Colors.deepPurple)),
                          const SizedBox(width: 6),
                        ],
                        if (ownerBrings && ownerCollects)
                          const Text('Owner brings & collects',
                              style: TextStyle(fontSize: 10, color: Colors.teal))
                        else if (ownerBrings)
                          const Text('Owner drops off',
                              style: TextStyle(fontSize: 10, color: Colors.teal))
                        else if (ownerCollects)
                          const Text('Owner picks up',
                              style: TextStyle(fontSize: 10, color: Colors.indigo)),
                      ]),
                  ],
                ),
              ),
              if (status != null) _statusTick(status!),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusTick(AssignmentStatus status) {
    switch (status) {
      case AssignmentStatus.assigned:
        return Picon(PiconsDuotone.clipboardText, size: 16, color: Colors.orange);
      case AssignmentStatus.pickedUp:
        return const Icon(Icons.check, size: 16, color: AppColors.success);
      case AssignmentStatus.droppedOff:
        return const Icon(Icons.done_all, size: 16, color: AppColors.success);
    }
  }
}
