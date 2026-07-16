import 'dart:async';

import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../constants/app_colors.dart';
import '../constants/pickup_map.dart';
import '../models/daily_dog_assignment.dart';
import '../models/dog.dart';
import '../services/cache_service.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/assignment_action_dialogs.dart';
import '../widgets/dog_quick_info_sheet.dart';
import 'dog_home_screen.dart';

/// Card/text sizing for the board, cycled from the app bar and persisted
/// on-device. Compact and dense scale the whole card down — column width,
/// photo, padding and text together — so more staff columns and more dogs
/// fit on screen at once without dropping any information.
enum _BoardDensity {
  comfortable,
  compact,
  dense;

  String get label => switch (this) {
        comfortable => 'Comfortable',
        compact => 'Compact',
        dense => 'Dense',
      };

  double get columnWidth => switch (this) {
        comfortable => 260,
        compact => 212,
        dense => 174,
      };

  /// Dog photo diameter on a card.
  double get avatarSize => switch (this) {
        comfortable => 36,
        compact => 30,
        dense => 24,
      };

  double get nameFontSize => switch (this) {
        comfortable => 14,
        compact => 12.5,
        dense => 11,
      };

  /// Transport/boarding hint line under the name.
  double get hintFontSize => switch (this) {
        comfortable => 10,
        compact => 9,
        dense => 8,
      };

  /// Pickup-run number badge on the photo.
  double get badgeSize => switch (this) {
        comfortable => 17,
        compact => 15,
        dense => 13,
      };

  double get statusIconSize => switch (this) {
        comfortable => 16,
        compact => 14,
        dense => 12,
      };

  double get rowVerticalPadding => switch (this) {
        comfortable => 6,
        compact => 4,
        dense => 3,
      };

  double get rowHorizontalPadding => switch (this) {
        comfortable => 8,
        compact => 6,
        dense => 5,
      };

  /// Gap below each card, and between the photo and the name.
  double get rowSpacing => switch (this) {
        comfortable => 6,
        compact => 4,
        dense => 3,
      };

  double get columnListPadding => switch (this) {
        comfortable => 8,
        compact => 6,
        dense => 5,
      };

  double get headerAvatarRadius => switch (this) {
        comfortable => 14,
        compact => 12,
        dense => 11,
      };

  double get headerNameFontSize => switch (this) {
        comfortable => 15,
        compact => 13.5,
        dense => 12.5,
      };
}

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
  final CacheService _cacheService = CacheService();

  late List<DailyDogAssignment> _assignments;
  late List<Dog> _unassignedDogs;
  late final StaffColorResolver _staffColors;
  bool _busy = false;
  bool _dataChanged = false;

  /// Manual show/hide choices per staff column; anyone not in the map follows
  /// the default (working staff shown, off staff hidden unless they have dogs).
  final Map<int, bool> _columnOverrides = {};
  bool _showUnassigned = true;

  /// Card/text size, cycled from the app bar and persisted with the column
  /// prefs so it sticks across visits.
  _BoardDensity _density = _BoardDensity.comfortable;

  /// While a dog is being dragged, the board condenses into one-screen staff
  /// tiles. Hovering a tile for a moment expands that member's run so the dog
  /// can be placed at an exact position.
  _DragItem? _dragging;
  int? _expandedStaffId;
  int? _hoverStaffId;
  Timer? _hoverTimer;
  static const Duration _expandHoverDelay = Duration(milliseconds: 650);

  void _onDragStarted(_DragItem item) => setState(() => _dragging = item);

  void _onDragFinished() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    if (!mounted) return;
    setState(() {
      _dragging = null;
      _expandedStaffId = null;
      _hoverStaffId = null;
    });
  }

  /// Hovering over [staffId]'s tile: expand their run after a short hold so a
  /// quick pass-over doesn't flicker the board.
  void _onTileHover(int staffId) {
    if (_expandedStaffId == staffId || _hoverStaffId == staffId) return;
    _hoverTimer?.cancel();
    _hoverStaffId = staffId;
    _hoverTimer = Timer(_expandHoverDelay, () {
      if (mounted && _dragging != null) {
        setState(() => _expandedStaffId = staffId);
      }
    });
  }

  void _onTileHoverEnd(int staffId) {
    if (_hoverStaffId == staffId) {
      _hoverTimer?.cancel();
      _hoverTimer = null;
      _hoverStaffId = null;
    }
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _assignments = List.of(widget.assignments);
    _unassignedDogs = List.of(widget.unassignedDogs);
    _staffColors = StaffColorResolver(widget.staffMembers);
    _restoreColumnPrefs();
  }

  /// Restore the show/hide column choices persisted on-device, so they
  /// survive leaving the board and app restarts.
  void _restoreColumnPrefs() {
    final prefs = _cacheService.getCachedDayBoardColumns();
    if (prefs == null) return;
    _showUnassigned = prefs['show_unassigned'] is bool ? prefs['show_unassigned'] as bool : true;
    final overrides = prefs['overrides'];
    if (overrides is Map) {
      overrides.forEach((key, value) {
        final id = int.tryParse(key.toString());
        if (id != null && value is bool) _columnOverrides[id] = value;
      });
    }
    final density = prefs['density'];
    if (density is String) {
      _density = _BoardDensity.values.firstWhere(
        (d) => d.name == density,
        orElse: () => _BoardDensity.comfortable,
      );
    }
  }

  void _saveColumnPrefs() {
    _cacheService.cacheDayBoardColumns({
      'show_unassigned': _showUnassigned,
      'density': _density.name,
      'overrides': {
        for (final entry in _columnOverrides.entries) '${entry.key}': entry.value,
      },
    });
  }

  void _cycleDensity() {
    setState(() {
      _density = _BoardDensity
          .values[(_density.index + 1) % _BoardDensity.values.length];
    });
    _saveColumnPrefs();
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
  /// no-staff-transport dogs (owner handles both legs, or mid-boarding dogs
  /// already with staff) at the end — they have no run position.
  List<DailyDogAssignment> _dogsFor(int staffId) {
    final run = <DailyDogAssignment>[];
    final ownerHandled = <DailyDogAssignment>[];
    for (final a in _assignments.where((a) => a.staffMemberId == staffId)) {
      (a.noStaffTransport ? ownerHandled : run).add(a);
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

  /// The ids of a staff member's pickup run, in run order (excludes dogs
  /// with no staff transport today — they hold no run position).
  List<int> _runIds(int staffId) => _dogsFor(staffId)
      .where((a) => !a.noStaffTransport)
      .map((a) => a.id)
      .toList();

  /// Drop onto a staff member: append to their run, or — when [insertIndex]
  /// is given (from the expanded placement view) — slot in at that position.
  Future<void> _dropOnStaff(_DragItem item, int staffId, {int? insertIndex}) async {
    final assignment = item.assignment;
    if (assignment == null) {
      // Unassigned dog → assign to this staff member (positioned if asked).
      await _guarded(() async {
        final result = await _dataService
            .assignDogs([int.parse(item.dog!.id)], staffId, date: widget.date);
        if (insertIndex != null && result.created.isNotEmpty) {
          final ids = _runIds(staffId)
            ..insert(insertIndex.clamp(0, _runIds(staffId).length), result.created.first.id);
          await _dataService.reorderAssignments(ids);
        }
        await _reload();
      });
      return;
    }
    if (assignment.staffMemberId == staffId) {
      // Same staff → reorder the pickup run.
      if (insertIndex == null) return; // dropped back on their own tile
      await _guarded(() async {
        final ids = _runIds(staffId)..remove(assignment.id);
        ids.insert(insertIndex.clamp(0, ids.length), assignment.id);
        await _dataService.reorderAssignments(ids);
        await _reload();
      });
      return;
    }
    // Different staff → reassign, then position on the new run if asked.
    await _guarded(() async {
      await _dataService.reassignDog(assignment.id, staffId);
      if (insertIndex != null) {
        final ids = _runIds(staffId); // target run before the move
        ids.insert(insertIndex.clamp(0, ids.length), assignment.id);
        await _dataService.reorderAssignments(ids);
      }
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
            _saveColumnPrefs();
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
              icon: Icon(switch (_density) {
                _BoardDensity.comfortable => Icons.density_large,
                _BoardDensity.compact => Icons.density_medium,
                _BoardDensity.dense => Icons.density_small,
              }),
              tooltip: 'Card size: ${_density.label} — tap to change',
              onPressed: _cycleDensity,
            ),
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
        // The column view must stay MOUNTED (Offstage, not removed) while the
        // drag overview shows: it contains the active LongPressDraggable, and
        // Flutter only delivers onDragEnd/onDraggableCanceled to a mounted
        // draggable. Swapping it out of the tree meant the drag never
        // "finished", leaving the board stuck on the overview after a drop.
        body: Stack(
          // Expand so the stack keeps the body's size while the column view
          // is offstage (an offstage child otherwise collapses the stack).
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: _dragging != null,
              child: (!_showUnassigned && columns.isEmpty)
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
            if (_dragging != null) Positioned.fill(child: _buildDragOverview(columns)),
          ],
        ),
      ),
    );
  }

  // ---- Drag overview (shown while a dog is being dragged) ----

  /// Condensed one-screen view: a tile per visible staff member (plus
  /// Unassigned when the drag can unassign). Release over a tile to add the
  /// dog to that member; hold over a tile to expand their run and place the
  /// dog at an exact position.
  Widget _buildDragOverview(List<({int id, String name})> columns) {
    if (_expandedStaffId != null) {
      final staff = _staffColumns.firstWhere(
        (s) => s.id == _expandedStaffId,
        orElse: () => (id: _expandedStaffId!, name: '?'),
      );
      return _buildExpandedPlacement(staff);
    }

    final showUnassignTile = _dragging?.assignment != null && widget.canAssignDogs;
    final tiles = <Widget>[
      if (showUnassignTile) _buildOverviewTile(staffId: null, name: 'Unassigned'),
      for (final staff in columns) _buildOverviewTile(staffId: staff.id, name: staff.name),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'Drop on a staff member to add ${_dragging?.dogName ?? 'the dog'} — hold over them to pick a position.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const crossAxisCount = 3;
              final rows = (tiles.length / crossAxisCount).ceil().clamp(1, 100);
              final tileWidth = (constraints.maxWidth - 32 - (crossAxisCount - 1) * 8) / crossAxisCount;
              final tileHeight =
                  ((constraints.maxHeight - 16 - (rows - 1) * 8) / rows).clamp(56.0, 140.0);
              return GridView.count(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: tileWidth / tileHeight,
                children: tiles,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildOverviewTile({required int? staffId, required String name}) {
    final color = staffId == null ? kUnassignedColor : _staffColors.of(staffId);
    final count = staffId == null ? _unassignedDogs.length : _dogsFor(staffId).length;
    final isOff = staffId != null && !_isWorking(staffId);

    return DragTarget<_DragItem>(
      onWillAcceptWithDetails: (details) => _canDrop(details.data, staffId),
      onMove: staffId != null ? (_) => _onTileHover(staffId) : null,
      onLeave: staffId != null ? (_) => _onTileHoverEnd(staffId) : null,
      onAcceptWithDetails: (details) {
        if (staffId != null) _onTileHoverEnd(staffId);
        staffId == null
            ? _dropOnUnassigned(details.data)
            : _dropOnStaff(details.data, staffId);
      },
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            color: highlighted
                ? color.withValues(alpha: 0.25)
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: highlighted ? color : color.withValues(alpha: 0.4),
              width: highlighted ? 3 : 1.5,
            ),
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: color,
                child: staffId == null
                    ? const Icon(Icons.person_off_outlined, color: Colors.white, size: 16)
                    : Text(name.isEmpty ? '?' : name[0],
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 4),
              Text(
                isOff ? '$name (off)' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
              Text('$count dog${count == 1 ? '' : 's'}',
                  style: TextStyle(
                      fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        );
      },
    );
  }

  /// Expanded placement view for one staff member during a drag: their pickup
  /// run with a drop slot before each dog (and one at the end). Hovering the
  /// bar at the top goes back to the staff tiles.
  Widget _buildExpandedPlacement(({int id, String name}) staff) {
    final color = _staffColors.of(staff.id);
    final run = _dogsFor(staff.id)
        .where((a) => !a.noStaffTransport)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hover here to collapse back to the tiles.
          DragTarget<_DragItem>(
            onWillAcceptWithDetails: (_) => false,
            onMove: (_) {
              _hoverTimer?.cancel();
              _hoverStaffId = null;
              setState(() => _expandedStaffId = null);
            },
            builder: (context, candidates, rejected) => Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.arrow_back, size: 16),
                  const SizedBox(width: 6),
                  Text('All staff',
                      style: TextStyle(
                          fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: color,
                child: Text(staff.name.isEmpty ? '?' : staff.name[0],
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              Text(staff.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('drop where ${_dragging?.dogName ?? 'the dog'} should go',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < run.length; i++) ...[
                  _buildPlacementSlot(staff.id, i, color),
                  IgnorePointer(
                    child: _DogRow(
                      name: run[i].dogName,
                      imageUrl: run[i].dogProfileImage,
                      number: i + 1,
                      color: color,
                      status: run[i].status,
                      isBoarding: run[i].isBoarding,
                      onTap: () {},
                    ),
                  ),
                ],
                _buildPlacementSlot(staff.id, run.length, color, label: 'Add to end'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A drop slot at [insertIndex] on [staffId]'s run.
  Widget _buildPlacementSlot(int staffId, int insertIndex, Color color, {String? label}) {
    return DragTarget<_DragItem>(
      onWillAcceptWithDetails: (details) => _canDrop(details.data, staffId),
      onAcceptWithDetails: (details) =>
          _dropOnStaff(details.data, staffId, insertIndex: insertIndex),
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty;
        return Container(
          height: highlighted ? 40 : 26,
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: highlighted ? color.withValues(alpha: 0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: highlighted ? color : color.withValues(alpha: 0.35),
              width: highlighted ? 2 : 1,
              // Dashed feel via low-alpha solid border; keep it simple.
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label ?? (highlighted ? 'Place here' : ''),
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
          ),
        );
      },
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
    final pickupLeg = dogs.where((a) => a.needsPickup).toList();
    final collected = pickupLeg
        .where((a) =>
            a.status == AssignmentStatus.pickedUp || a.status == AssignmentStatus.droppedOff)
        .length;

    // Drops land on the drag-overview tiles (the board condenses as soon as a
    // drag starts), so the full column is display-only.
    final count = staffId == null ? unassigned.length : dogs.length;
    return Container(
          width: _density.columnWidth,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: color.withValues(alpha: 0.35),
              width: 1.5,
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
                      radius: _density.headerAvatarRadius,
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
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: _density.headerNameFontSize),
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
                          staffId == null ? 'No unassigned dogs' : 'No dogs yet',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                        ),
                      )
                    : ListView(
                        padding: EdgeInsets.all(_density.columnListPadding),
                        children: staffId == null
                            ? [for (final d in unassigned) _buildUnassignedRow(d)]
                            : [for (final a in dogs) _buildDogRow(a, staffId)],
                      ),
              ),
            ],
          ),
        );
  }

  /// Tap on a dog: quick-info sheet with a reassign shortcut in its corner
  /// (permission-gated), and full-profile navigation.
  Future<void> _openQuickInfo({DailyDogAssignment? assignment, Dog? dog}) async {
    final fullDog = await DogQuickInfoSheet.show(
      context,
      assignment: assignment,
      dog: dog,
      onReassign: assignment != null && widget.canAssignDogs
          ? () => _reassignViaPicker(assignment)
          : null,
    );
    if (fullDog != null && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DogHomeScreen(dog: fullDog, isStaff: true)),
      );
      if (mounted) _reload();
    }
  }

  /// Reassign via the shared staff picker (same dialog as the other screens).
  Future<void> _reassignViaPicker(DailyDogAssignment assignment) async {
    final staffId = await pickStaffMember(
      context,
      title: 'Reassign ${assignment.dogName}',
      currentStaffId: assignment.staffMemberId,
      initialStaffMembers: widget.staffMembers,
      initialAvailableStaffIds: widget.availableStaffIds,
      loadStaff: () => _dataService.getStaffMembers(),
      loadAvailableIds: () => _dataService.getAvailableStaffForDate(widget.date),
    );
    if (staffId == null || staffId == assignment.staffMemberId) return;
    await _guarded(() async {
      await _dataService.reassignDog(assignment.id, staffId);
      await _reload();
    });
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
      density: _density,
      onTap: () => _openQuickInfo(assignment: a),
    );
    return _draggable(_DragItem.assignment(a), row);
  }

  Widget _buildUnassignedRow(Dog d) {
    final row = _DogRow(
      key: ValueKey('d${d.id}'),
      name: d.name,
      imageUrl: d.profileImageUrl,
      number: null,
      color: kUnassignedColor,
      status: null,
      density: _density,
      onTap: () => _openQuickInfo(dog: d),
    );
    return _draggable(_DragItem.dog(d), row);
  }

  Widget _draggable(_DragItem item, Widget row) {
    return LongPressDraggable<_DragItem>(
      data: item,
      maxSimultaneousDrags: _busy ? 0 : 1,
      onDragStarted: () => _onDragStarted(item),
      onDragEnd: (_) => _onDragFinished(),
      onDraggableCanceled: (_, __) => _onDragFinished(),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: _density.columnWidth - 24,
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
/// transport/boarding hints and a status tick. All sizes scale with
/// [density] so compact/dense boards fit more on screen.
class _DogRow extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final int? number;
  final Color color;
  final AssignmentStatus? status;
  final bool ownerBrings;
  final bool ownerCollects;
  final bool isBoarding;
  final _BoardDensity density;
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
    this.density = _BoardDensity.comfortable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = density.avatarSize;
    final hintStyleTeal =
        TextStyle(fontSize: density.hintFontSize, color: Colors.teal);
    return Card(
      margin: EdgeInsets.only(bottom: density.rowSpacing),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: density.rowHorizontalPadding,
              vertical: density.rowVerticalPadding),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  imageUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(avatar / 2),
                          child: CachedNetworkImage(
                            imageUrl: imageUrl!,
                            width: avatar,
                            height: avatar,
                            fit: BoxFit.cover,
                            memCacheWidth:
                                (avatar * MediaQuery.of(context).devicePixelRatio).round(),
                            memCacheHeight:
                                (avatar * MediaQuery.of(context).devicePixelRatio).round(),
                            placeholder: (context, url) => Container(
                                width: avatar,
                                height: avatar,
                                color: Colors.grey[200],
                                child: Picon(PiconsDuotone.pawPrint, size: avatar / 2)),
                            errorWidget: (context, url, error) => CircleAvatar(
                                radius: avatar / 2,
                                child: Picon(PiconsDuotone.pawPrint, size: avatar / 2)),
                          ),
                        )
                      : CircleAvatar(
                          radius: avatar / 2,
                          child: Picon(PiconsDuotone.pawPrint, size: avatar / 2)),
                  if (number != null)
                    Positioned(
                      left: -5,
                      top: -5,
                      child: Container(
                        width: density.badgeSize,
                        height: density.badgeSize,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Text('$number',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: density.hintFontSize,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                ],
              ),
              SizedBox(width: density.rowSpacing + 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: density.nameFontSize)),
                    if (ownerBrings || ownerCollects || isBoarding)
                      Row(children: [
                        if (isBoarding) ...[
                          Picon(PiconsDuotone.bed,
                              size: density.hintFontSize + 2, color: Colors.deepPurple),
                          const SizedBox(width: 2),
                          Text('Boarding',
                              style: TextStyle(
                                  fontSize: density.hintFontSize,
                                  color: Colors.deepPurple)),
                          const SizedBox(width: 6),
                        ],
                        if (ownerBrings && ownerCollects)
                          Text('Owner brings & collects', style: hintStyleTeal)
                        else if (ownerBrings)
                          Text('Owner drops off', style: hintStyleTeal)
                        else if (ownerCollects)
                          Text('Owner picks up',
                              style: TextStyle(
                                  fontSize: density.hintFontSize,
                                  color: Colors.indigo)),
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
    final size = density.statusIconSize;
    switch (status) {
      case AssignmentStatus.assigned:
        return Picon(PiconsDuotone.clipboardText, size: size, color: Colors.orange);
      case AssignmentStatus.pickedUp:
        return Icon(Icons.check, size: size, color: AppColors.success);
      case AssignmentStatus.droppedOff:
        return Icon(Icons.done_all, size: size, color: AppColors.success);
    }
  }
}
