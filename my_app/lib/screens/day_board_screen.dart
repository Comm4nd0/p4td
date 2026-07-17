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

/// Continuous card/text sizing for the board, driven by pinch-zoom on the
/// board itself and by the app-bar presets. The board always opens fully
/// zoomed out — the most-on-screen view — and pinching adjusts it for the
/// current visit only.
///
/// Unlike an image-style zoom (which only scales pixels and leaves blank
/// space), the scale feeds the actual layout: pinching in makes columns and
/// cards genuinely smaller so more staff and more dogs fit on screen, with
/// nothing dropped. Boxes/paddings scale linearly; text follows a gentler
/// curve so names stay readable at the smallest sizes.
class _BoardSizing {
  /// 1.0 = the board's original ("comfortable") look.
  final double scale;

  const _BoardSizing(this.scale);

  static const double min = 0.55;
  static const double max = 1.25;

  /// Preset stops for the app-bar button (comfortable / compact / dense).
  static const double comfortable = 1.0;
  static const double compact = 0.82;
  static const double dense = 0.67;

  double get _text => 0.5 + 0.5 * scale;

  String get label => scale > 0.9
      ? 'Comfortable'
      : scale > 0.72
          ? 'Compact'
          : 'Dense';

  double get columnWidth => 260 * scale;

  /// Dog photo diameter on a card.
  double get avatarSize => 36 * scale;

  double get nameFontSize => 14 * _text;

  /// Transport/boarding hint line under the name.
  double get hintFontSize => 10 * _text;

  /// Pickup-run number badge on the photo.
  double get badgeSize => 17 * _text;

  double get statusIconSize => 16 * _text;

  double get rowVerticalPadding => 6 * scale;

  double get rowHorizontalPadding => 8 * scale;

  /// Gap below each card, and between the photo and the name.
  double get rowSpacing => 6 * scale;

  double get columnListPadding => 8 * scale;

  double get headerAvatarRadius => 14 * _text;

  double get headerNameFontSize => 15 * _text;
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

  /// Board zoom: always opens fully zoomed out so the whole day fits on
  /// screen; pinch or the app-bar presets zoom in for a closer look.
  double _boardScale = _BoardSizing.min;
  double _pinchStartScale = _BoardSizing.min;

  _BoardSizing get _sizing => _BoardSizing(_boardScale);

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
  }

  void _saveColumnPrefs() {
    _cacheService.cacheDayBoardColumns({
      'show_unassigned': _showUnassigned,
      'overrides': {
        for (final entry in _columnOverrides.entries) '${entry.key}': entry.value,
      },
    });
  }

  /// App-bar button: jump to the next preset stop (comfortable → compact →
  /// dense → comfortable), from wherever pinching has left the scale.
  void _cycleSizePreset() {
    setState(() {
      _boardScale = _boardScale > 0.9
          ? _BoardSizing.compact
          : _boardScale > 0.72
              ? _BoardSizing.dense
              : _BoardSizing.comfortable;
    });
  }

  // Pinch-zoom on the board: two fingers rescale the layout live. One-finger
  // drags stay with the lists.
  void _onPinchStart(ScaleStartDetails details) {
    _pinchStartScale = _boardScale;
  }

  void _onPinchUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount < 2) return;
    final next = (_pinchStartScale * details.scale)
        .clamp(_BoardSizing.min, _BoardSizing.max);
    if (next != _boardScale) setState(() => _boardScale = next);
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
              icon: Icon(_boardScale > 0.9
                  ? Icons.density_large
                  : _boardScale > 0.72
                      ? Icons.density_medium
                      : Icons.density_small),
              tooltip:
                  'Card size: ${_sizing.label} — tap to change, or pinch the board',
              onPressed: _cycleSizePreset,
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
                  // Two-finger pinch rescales the board layout (more columns
                  // and dogs on screen, not just smaller pixels); one-finger
                  // drags keep scrolling the lists as before.
                  : GestureDetector(
                      onScaleStart: _onPinchStart,
                      onScaleUpdate: _onPinchUpdate,
                      child: ListView(
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
          width: _sizing.columnWidth,
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
                      radius: _sizing.headerAvatarRadius,
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
                            fontSize: _sizing.headerNameFontSize),
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
                        padding: EdgeInsets.all(_sizing.columnListPadding),
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
      sizing: _sizing,
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
      sizing: _sizing,
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
          width: _sizing.columnWidth - 24,
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
/// [sizing] so zoomed-out boards fit more on screen.
class _DogRow extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final int? number;
  final Color color;
  final AssignmentStatus? status;
  final bool ownerBrings;
  final bool ownerCollects;
  final bool isBoarding;
  final _BoardSizing sizing;
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
    this.sizing = const _BoardSizing(_BoardSizing.comfortable),
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = sizing.avatarSize;
    final hintStyleTeal =
        TextStyle(fontSize: sizing.hintFontSize, color: Colors.teal);
    return Card(
      margin: EdgeInsets.only(bottom: sizing.rowSpacing),
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
              horizontal: sizing.rowHorizontalPadding,
              vertical: sizing.rowVerticalPadding),
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
                        width: sizing.badgeSize,
                        height: sizing.badgeSize,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Text('$number',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: sizing.hintFontSize,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                ],
              ),
              SizedBox(width: sizing.rowSpacing + 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: sizing.nameFontSize)),
                    if (ownerBrings || ownerCollects || isBoarding)
                      Row(children: [
                        if (isBoarding) ...[
                          Picon(PiconsDuotone.bed,
                              size: sizing.hintFontSize + 2, color: Colors.deepPurple),
                          const SizedBox(width: 2),
                          Text('Boarding',
                              style: TextStyle(
                                  fontSize: sizing.hintFontSize,
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
                                  fontSize: sizing.hintFontSize,
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
    final size = sizing.statusIconSize;
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
