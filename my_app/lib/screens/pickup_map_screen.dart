import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_colors.dart';
import '../constants/pickup_map.dart';
import '../models/daily_dog_assignment.dart';
import '../models/dog.dart';
import '../services/data_service.dart';
import '../utils/date_formats.dart';
import 'staff_dog_detail_screen.dart';

/// A staff member's route geometry: base → their dogs (in list order) → base.
class _Route {
  final int staffId;
  final Color color;
  final List<LatLng> points;
  _Route(this.staffId, this.color, this.points);
}

/// One plottable pickup on the map: either an assigned dog (coloured by staff)
/// or an unassigned/rostered dog (grey).
class _Pin {
  final LatLng position;
  final Color color;
  final bool atBase;
  final DailyDogAssignment? assignment; // null for unassigned dogs
  final Dog? dog; // set for unassigned dogs
  final int? staffId;
  final String dogName;
  final String? address;

  _Pin({
    required this.position,
    required this.color,
    required this.atBase,
    required this.dogName,
    this.assignment,
    this.dog,
    this.staffId,
    this.address,
  });
}

/// Staff pickup map: a pin per dog at its pickup address, coloured by the staff
/// member assigned to it, with per-staff show/hide toggles. Dogs with no
/// address are pinned at base. Built to make geographic workload obvious so
/// dogs can be rebalanced between staff.
class PickupMapScreen extends StatefulWidget {
  final DateTime date;
  final List<DailyDogAssignment> assignments;
  final List<Dog> unassignedDogs;
  final List<Map<String, dynamic>> staffMembers;
  final Set<int> availableStaffIds;
  final bool canAssignDogs;

  const PickupMapScreen({
    super.key,
    required this.date,
    required this.assignments,
    this.unassignedDogs = const [],
    this.staffMembers = const [],
    this.availableStaffIds = const {},
    this.canAssignDogs = false,
  });

  @override
  State<PickupMapScreen> createState() => _PickupMapScreenState();
}

class _PickupMapScreenState extends State<PickupMapScreen> with SingleTickerProviderStateMixin {
  final DataService _dataService = ApiDataService();
  final MapController _mapController = MapController();

  /// Drives the dot that travels along each route to show direction of travel.
  late final AnimationController _routeAnim;

  late List<DailyDogAssignment> _assignments;
  late List<Dog> _unassignedDogs;

  /// Staff display names whose pins are hidden by default (still toggleable).
  /// "P4TD" is the business's own pseudo-staff bucket (e.g. daycare/at-base
  /// dogs), which would otherwise clutter the pickup view.
  static const Set<String> _defaultHiddenStaffNames = {'p4td'};

  /// Staff whose pins are currently hidden.
  final Set<int> _hiddenStaffIds = {};
  bool _showUnassigned = true;
  // "At base (no address)" pins are hidden by default — they all stack on the
  // depot and aren't useful for planning pickups. Toggleable in the legend.
  bool _showBase = false;
  // Route lines per staff (base → dogs in list order → base).
  bool _showRoutes = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _assignments = List.of(widget.assignments);
    _unassignedDogs = List.of(widget.unassignedDogs);
    // Default-hide the P4TD pseudo-staff member's pins (still toggleable).
    _staffNames().forEach((id, name) {
      if (_defaultHiddenStaffNames.contains(name.trim().toLowerCase())) {
        _hiddenStaffIds.add(id);
      }
    });
    _routeAnim = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();
  }

  @override
  void dispose() {
    _routeAnim.dispose();
    super.dispose();
  }

  /// All staff ids in a stable order, so each staff member maps to a fixed
  /// colour slot regardless of which subset is on the map today.
  List<int> get _orderedStaffIds {
    final ids = widget.staffMembers
        .map((s) => s['id'] as int)
        .toList();
    if (ids.isEmpty) {
      ids.addAll(_assignments.map((a) => a.staffMemberId).toSet());
    }
    ids.sort();
    return ids;
  }

  LatLng _positionFor(double? lat, double? lng) =>
      (lat != null && lng != null) ? LatLng(lat, lng) : const LatLng(kBaseLatitude, kBaseLongitude);

  /// Build the full pin list honouring the current toggles.
  List<_Pin> _visiblePins() {
    final ordered = _orderedStaffIds;
    final pins = <_Pin>[];

    for (final a in _assignments) {
      if (_hiddenStaffIds.contains(a.staffMemberId)) continue;
      final atBase = a.latitude == null || a.longitude == null;
      if (atBase && !_showBase) continue;
      pins.add(_Pin(
        position: _positionFor(a.latitude, a.longitude),
        color: staffColor(a.staffMemberId, ordered),
        atBase: atBase,
        assignment: a,
        staffId: a.staffMemberId,
        dogName: a.dogName,
        address: a.ownerAddress,
      ));
    }

    if (_showUnassigned) {
      for (final d in _unassignedDogs) {
        final atBase = d.latitude == null || d.longitude == null;
        if (atBase && !_showBase) continue;
        pins.add(_Pin(
          position: _positionFor(d.latitude, d.longitude),
          color: kUnassignedColor,
          atBase: atBase,
          dog: d,
          dogName: d.name,
          address: d.address,
        ));
      }
    }
    return pins;
  }

  // ─── Counts for the legend ──────────────────────────────────────────

  Map<int, int> _assignmentCountsByStaff() {
    final counts = <int, int>{};
    for (final a in _assignments) {
      counts[a.staffMemberId] = (counts[a.staffMemberId] ?? 0) + 1;
    }
    return counts;
  }

  /// A dog counts as "collected" once it's no longer just assigned — i.e. it's
  /// with the team (picked up) or already dropped off.
  bool _isCollected(DailyDogAssignment a) =>
      a.status == AssignmentStatus.pickedUp || a.status == AssignmentStatus.droppedOff;

  Map<int, int> _collectedCountsByStaff() {
    final counts = <int, int>{};
    for (final a in _assignments) {
      if (_isCollected(a)) counts[a.staffMemberId] = (counts[a.staffMemberId] ?? 0) + 1;
    }
    return counts;
  }

  Map<int, String> _staffNames() {
    final names = <int, String>{};
    for (final s in widget.staffMembers) {
      final id = s['id'] as int;
      final fn = (s['first_name'] ?? '').toString();
      names[id] = fn.isNotEmpty ? fn : (s['username'] ?? 'Staff').toString();
    }
    // Fall back to names carried on the assignments.
    for (final a in _assignments) {
      names.putIfAbsent(a.staffMemberId, () => a.staffMemberName);
    }
    return names;
  }

  int get _baseCount {
    var n = 0;
    for (final a in _assignments) {
      if (a.latitude == null || a.longitude == null) n++;
    }
    for (final d in _unassignedDogs) {
      if (d.latitude == null || d.longitude == null) n++;
    }
    return n;
  }

  // ─── Initial camera ─────────────────────────────────────────────────

  LatLng _initialCenter() {
    final positions = <LatLng>[];
    for (final a in _assignments) {
      if (a.latitude != null && a.longitude != null) {
        positions.add(LatLng(a.latitude!, a.longitude!));
      }
    }
    for (final d in _unassignedDogs) {
      if (d.latitude != null && d.longitude != null) {
        positions.add(LatLng(d.latitude!, d.longitude!));
      }
    }
    if (positions.isEmpty) return const LatLng(kBaseLatitude, kBaseLongitude);
    final lat = positions.map((p) => p.latitude).reduce((a, b) => a + b) / positions.length;
    final lng = positions.map((p) => p.longitude).reduce((a, b) => a + b) / positions.length;
    return LatLng(lat, lng);
  }

  // ─── Refresh ────────────────────────────────────────────────────────

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final fresh = await _dataService.getTodayAssignments(date: widget.date);
      if (mounted) setState(() => _assignments = fresh);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to refresh: $e')));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // ─── Pin tap ────────────────────────────────────────────────────────

  void _showPinSheet(_Pin pin) {
    final names = _staffNames();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 14, height: 14, decoration: BoxDecoration(color: pin.color, shape: BoxShape.circle)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(pin.dogName, style: Theme.of(context).textTheme.titleLarge)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  pin.assignment != null
                      ? 'Assigned to ${names[pin.staffId] ?? pin.assignment!.staffMemberName}'
                      : 'Unassigned',
                  style: const TextStyle(color: AppColors.grey600),
                ),
                const SizedBox(height: 6),
                Text(
                  pin.atBase
                      ? 'No address — shown at base ($kBaseLabel)'
                      : (pin.address ?? 'No address'),
                  style: const TextStyle(color: AppColors.grey600, fontSize: 13),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (!pin.atBase)
                      OutlinedButton.icon(
                        onPressed: () => _openInMaps(pin.position),
                        icon: const Icon(Icons.directions, size: 18),
                        label: const Text('Directions'),
                      ),
                    const Spacer(),
                    if (widget.canAssignDogs && pin.assignment != null)
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _reassign(pin.assignment!);
                        },
                        icon: const Icon(Icons.swap_horiz, size: 18),
                        label: const Text('Reassign'),
                      )
                    else if (widget.canAssignDogs && pin.dog != null)
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _assign(pin.dog!);
                        },
                        icon: const Icon(Icons.person_add_alt, size: 18),
                        label: const Text('Assign'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openInMaps(LatLng p) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${p.latitude},${p.longitude}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {/* best effort */}
  }

  // ─── Reassign / assign (mirrors all_dogs_today_screen) ──────────────

  Future<void> _reassign(DailyDogAssignment assignment) async {
    final picked = await _pickStaffMember(
      title: 'Reassign ${assignment.dogName}',
      currentStaffId: assignment.staffMemberId,
      subtitle: 'Currently assigned to ${assignment.staffMemberName}',
      confirmLabel: 'Reassign',
    );
    if (picked == null || !mounted) return;
    final scope = await _promptAssignmentScope();
    if (scope == null) return;
    try {
      final updated = await _dataService.reassignDog(assignment.id, picked, scope: scope);
      if (mounted) {
        setState(() {
          final i = _assignments.indexWhere((a) => a.id == assignment.id);
          if (i >= 0) _assignments[i] = updated;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dog reassigned'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to reassign: $e')));
      }
    }
  }

  Future<void> _assign(Dog dog) async {
    final picked = await _pickStaffMember(title: 'Assign ${dog.name}', confirmLabel: 'Assign');
    if (picked == null || !mounted) return;
    try {
      final result = await _dataService.assignDogs([int.parse(dog.id)], picked, date: widget.date);
      if (mounted) {
        if (result.hasSkipped) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name}: ${result.skipped.first.reason}'), backgroundColor: AppColors.warning),
          );
        } else {
          setState(() {
            _assignments.addAll(result.created);
            _unassignedDogs.removeWhere((d) => d.id == dog.id);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${dog.name} assigned'), backgroundColor: AppColors.success),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to assign: $e')));
      }
    }
  }

  Future<AssignmentScope?> _promptAssignmentScope() {
    return showDialog<AssignmentScope>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply change'),
        content: const Text('Apply this change to only this day, or to every week going forward?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, AssignmentScope.justThisDay), child: const Text('Just this day')),
          FilledButton(onPressed: () => Navigator.pop(context, AssignmentScope.fromNowOn), child: const Text('From now on')),
        ],
      ),
    );
  }

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
        availableIds = staffMembers.map((s) => s['id'] as int).toSet();
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
                Text(subtitle, style: const TextStyle(color: AppColors.grey600, fontSize: 13)),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<int>(
                decoration: const InputDecoration(labelText: 'Staff member'),
                value: picked,
                items: staffMembers.map((s) {
                  final staffId = s['id'] as int;
                  final name = (s['first_name'] != null && s['first_name'].toString().isNotEmpty)
                      ? s['first_name'].toString()
                      : s['username'].toString();
                  final isAvailable = availableIds.isEmpty || availableIds.contains(staffId);
                  return DropdownMenuItem<int>(
                    value: staffId,
                    child: Row(children: [
                      Container(
                        width: 10, height: 10,
                        decoration: BoxDecoration(color: staffColor(staffId, _orderedStaffIds), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(name, style: TextStyle(color: isAvailable ? null : AppColors.grey500)),
                      if (!isAvailable) const Text(' (off)', style: TextStyle(fontSize: 11, color: AppColors.grey400)),
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

  // ─── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final pins = _visiblePins();
    final markers = pins.map(_buildMarker).toList();
    final routeGeoms = _routeGeometries();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            const Text('Routes Map'),
            Text(ukDateWithDay(widget.date),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _showRoutes ? 'Hide routes' : 'Show routes',
            icon: Icon(_showRoutes ? Icons.route : Icons.route_outlined),
            onPressed: () => setState(() => _showRoutes = !_showRoutes),
          ),
          IconButton(
            icon: _refreshing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _initialCenter(),
                initialZoom: 11,
                minZoom: 6,
                maxZoom: 18,
                // Lock the map to north-up: keep all gestures except rotation.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.paws4thoughtdogs.app',
                ),
                // Route lines sit under the markers so paws stay tappable.
                if (_showRoutes) PolylineLayer(polylines: _routeLines(routeGeoms)),
                if (_showRoutes)
                  AnimatedBuilder(
                    animation: _routeAnim,
                    builder: (_, __) => MarkerLayer(markers: _movingDots(routeGeoms, _routeAnim.value)),
                  ),
                if (markers.isNotEmpty)
                  MarkerClusterLayerWidget(
                    options: MarkerClusterLayerOptions(
                      maxClusterRadius: 45,
                      size: const Size(40, 40),
                      padding: const EdgeInsets.all(50),
                      markers: markers,
                      builder: (context, clusterMarkers) => Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Center(
                          child: Text('${clusterMarkers.length}',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                // Daycare/base landmark — its own layer so it's always visible
                // and never absorbed into a cluster count.
                MarkerLayer(markers: [_daycareMarker()]),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('© OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
          ),
          _buildLegend(),
        ],
      ),
    );
  }

  /// One route polyline per visible staff member: base → their dogs in list
  /// order (sortOrder, then name — matching the staff dog list) → base. Dogs
  /// with no address (pinned at base) are skipped so the line stays clean.
  List<_Route> _routeGeometries() {
    final ordered = _orderedStaffIds;
    final byStaff = <int, List<DailyDogAssignment>>{};
    for (final a in _assignments) {
      if (_hiddenStaffIds.contains(a.staffMemberId)) continue;
      if (a.latitude == null || a.longitude == null) continue;
      // Owner brings AND collects → no staff transport leg → not on the route.
      if (a.effectiveOwnerBrings && a.effectiveOwnerCollects) continue;
      byStaff.putIfAbsent(a.staffMemberId, () => []).add(a);
    }
    const base = LatLng(kBaseLatitude, kBaseLongitude);
    final routes = <_Route>[];
    byStaff.forEach((staffId, list) {
      list.sort((a, b) {
        final cmp = a.sortOrder.compareTo(b.sortOrder);
        if (cmp != 0) return cmp;
        return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
      });
      routes.add(_Route(
        staffId,
        staffColor(staffId, ordered),
        <LatLng>[base, for (final a in list) LatLng(a.latitude!, a.longitude!), base],
      ));
    });
    return routes;
  }

  List<Polyline> _routeLines(List<_Route> routes) => [
        for (final r in routes)
          Polyline(
            points: r.points,
            color: r.color.withValues(alpha: 0.85),
            strokeWidth: 3,
            borderColor: Colors.white,
            borderStrokeWidth: 1,
          ),
      ];

  /// A dot per route at fraction [t] along the path — its motion (base → dogs →
  /// base) shows the direction of travel.
  List<Marker> _movingDots(List<_Route> routes, double t) {
    final dots = <Marker>[];
    for (final r in routes) {
      if (r.points.length < 2) continue;
      dots.add(Marker(
        point: _alongPath(r.points, t),
        width: 12,
        height: 12,
        alignment: Alignment.center,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              color: r.color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ));
    }
    return dots;
  }

  LatLng _alongPath(List<LatLng> pts, double frac) {
    final segLen = <double>[];
    var total = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final d = _dist(pts[i], pts[i + 1]);
      segLen.add(d);
      total += d;
    }
    if (total == 0) return pts.first;
    var target = frac.clamp(0.0, 1.0) * total;
    for (var i = 0; i < segLen.length; i++) {
      if (target <= segLen[i] || i == segLen.length - 1) {
        final f = segLen[i] == 0 ? 0.0 : target / segLen[i];
        return LatLng(
          pts[i].latitude + (pts[i + 1].latitude - pts[i].latitude) * f,
          pts[i].longitude + (pts[i + 1].longitude - pts[i].longitude) * f,
        );
      }
      target -= segLen[i];
    }
    return pts.last;
  }

  double _dist(LatLng a, LatLng b) {
    final dx = a.latitude - b.latitude;
    final dy = a.longitude - b.longitude;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Jump from the map to a staff member's reorderable dog list, then refresh
  /// (so any reordering there updates the route here).
  Future<void> _openStaffList(int staffId, String name) async {
    final staffAssignments = _assignments.where((a) => a.staffMemberId == staffId).toList();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StaffDogDetailScreen(
          staffMemberId: staffId,
          staffMemberName: name,
          date: widget.date,
          assignments: staffAssignments,
          canAssignDogs: widget.canAssignDogs,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  Marker _buildMarker(_Pin pin) {
    final collected = pin.assignment != null && _isCollected(pin.assignment!);
    return Marker(
      point: pin.position,
      width: 44,
      height: 44,
      alignment: Alignment.center,
      child: GestureDetector(
        onTap: () => _showPinSheet(pin),
        child: Stack(
          alignment: Alignment.center,
          children: [
            _pawBadge(pin.color),
            if (collected)
              Positioned(right: 3, bottom: 3, child: _collectedTick()),
          ],
        ),
      ),
    );
  }

  /// A staff-coloured circular badge with a white paw — a dog pickup.
  Widget _pawBadge(Color color) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 1))],
      ),
      child: const Center(child: Icon(Icons.pets, color: Colors.white, size: 18)),
    );
  }

  /// Small green tick shown on a paw once the dog is with the team / collected.
  Widget _collectedTick() {
    return Container(
      width: 16,
      height: 16,
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
          child: const Icon(Icons.check, color: Colors.white, size: 10),
        ),
      ),
    );
  }

  /// The fixed daycare/base landmark — a larger teal house badge.
  Marker _daycareMarker() {
    return Marker(
      point: const LatLng(kBaseLatitude, kBaseLongitude),
      width: 46,
      height: 46,
      alignment: Alignment.center,
      child: GestureDetector(
        onTap: _showDaycareSheet,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 1))],
          ),
          child: const Center(child: Icon(Icons.home, color: Colors.white, size: 26)),
        ),
      ),
    );
  }

  void _showDaycareSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.home, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Paws 4 Thought Dogs', style: Theme.of(context).textTheme.titleLarge)),
                ],
              ),
              const SizedBox(height: 8),
              const Text('Daycare / base', style: TextStyle(color: AppColors.grey600)),
              const SizedBox(height: 6),
              const Text('Chiltern View, Henley Road, Medmenham, SL7 2HE',
                  style: TextStyle(color: AppColors.grey600, fontSize: 13)),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _openInMaps(const LatLng(kBaseLatitude, kBaseLongitude)),
                  icon: const Icon(Icons.directions, size: 18),
                  label: const Text('Directions'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLegend() {
    final counts = _assignmentCountsByStaff();
    final collected = _collectedCountsByStaff();
    final names = _staffNames();
    final staffIds = counts.keys.toList()..sort();
    final unassignedCount = _unassignedDogs.length;
    final baseCount = _baseCount;

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.32),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, -2))],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.home, size: 16, color: AppColors.primary),
                    SizedBox(width: 12),
                    Text('Daycare (base)'),
                  ],
                ),
              ),
              const Divider(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Staff', style: Theme.of(context).textTheme.titleMedium),
                  if (_hiddenStaffIds.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(_hiddenStaffIds.clear),
                      child: const Text('Show all'),
                    ),
                ],
              ),
              for (final id in staffIds)
                _legendRow(
                  color: staffColor(id, _orderedStaffIds),
                  label: names[id] ?? 'Staff',
                  count: counts[id] ?? 0,
                  collected: collected[id] ?? 0,
                  value: !_hiddenStaffIds.contains(id),
                  onTap: () => _openStaffList(id, names[id] ?? 'Staff'),
                  onChanged: (v) => setState(() {
                    if (v) {
                      _hiddenStaffIds.remove(id);
                    } else {
                      _hiddenStaffIds.add(id);
                    }
                  }),
                ),
              if (unassignedCount > 0)
                _legendRow(
                  color: kUnassignedColor,
                  label: 'Unassigned',
                  count: unassignedCount,
                  value: _showUnassigned,
                  onChanged: (v) => setState(() => _showUnassigned = v),
                ),
              if (baseCount > 0)
                _legendRow(
                  color: AppColors.grey700,
                  label: 'At base (no address)',
                  count: baseCount,
                  value: _showBase,
                  icon: Icons.home_outlined,
                  onChanged: (v) => setState(() => _showBase = v),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendRow({
    required Color color,
    required String label,
    required int count,
    required bool value,
    required ValueChanged<bool> onChanged,
    IconData? icon,
    int? collected,
    VoidCallback? onTap,
  }) {
    final content = Row(
      children: [
        icon != null
            ? Icon(icon, size: 16, color: color)
            : Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 12),
        Expanded(
          child: collected != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label),
                    Row(
                      children: [
                        const Icon(Icons.check_circle, size: 13, color: AppColors.success),
                        const SizedBox(width: 4),
                        Text('collected $collected of $count',
                            style: const TextStyle(fontSize: 12, color: AppColors.grey600)),
                      ],
                    ),
                  ],
                )
              : Text('$label  ($count)'),
        ),
        if (onTap != null) const Icon(Icons.chevron_right, size: 18, color: AppColors.grey400),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: onTap != null
                ? InkWell(onTap: onTap, child: content)
                : content,
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
