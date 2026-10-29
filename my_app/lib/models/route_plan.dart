/// Route planning suggestions from `daily-assignments/optimise_route/` and
/// `plan_routes/`. Nothing here is saved until staff accept it: an
/// optimised order goes through `reorder/`, a plan through
/// `apply_route_plan/`.
library;

int? _intOrNull(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);

/// The suggested order for one driver's run.
class RouteOptimisation {
  final int staffMemberId;

  /// Every routed dog's assignment id, in the suggested order. Dogs with no
  /// location on file come last, in their current order.
  final List<int> assignmentIds;
  final List<RouteStop> dogs;
  final int currentMinutes;
  final int optimisedMinutes;
  final List<String> unlocated;

  const RouteOptimisation({
    required this.staffMemberId,
    required this.assignmentIds,
    required this.dogs,
    required this.currentMinutes,
    required this.optimisedMinutes,
    this.unlocated = const [],
  });

  int get minutesSaved => currentMinutes - optimisedMinutes;

  factory RouteOptimisation.fromJson(Map<String, dynamic> json) => RouteOptimisation(
        staffMemberId: json['staff_member_id'],
        assignmentIds: (json['assignment_ids'] as List).cast<int>(),
        dogs: (json['dogs'] as List).map((d) => RouteStop.fromJson(d)).toList(),
        currentMinutes: json['current_minutes'] ?? 0,
        optimisedMinutes: json['optimised_minutes'] ?? 0,
        unlocated: (json['unlocated'] as List? ?? const []).cast<String>(),
      );
}

class RouteStop {
  final int assignmentId;
  final int dogId;
  final String name;
  final bool located;

  const RouteStop({required this.assignmentId, required this.dogId, required this.name, required this.located});

  factory RouteStop.fromJson(Map<String, dynamic> json) => RouteStop(
        assignmentId: json['assignment_id'],
        dogId: json['dog_id'],
        name: json['name'] ?? '',
        located: json['located'] ?? true,
      );
}

/// A staff member Plan Routes can give dogs to, from `route_plan_drivers/`.
class RoutePlanDriver {
  final int staffMemberId;
  final String name;
  final String? vehicleName;

  /// Dogs the usual vehicle carries; null when nobody has set it.
  final int? capacity;
  final int dogsNow;
  final bool working;

  /// Ticked by default: due in that day, or already holding dogs.
  final bool selected;

  const RoutePlanDriver({
    required this.staffMemberId,
    required this.name,
    this.vehicleName,
    this.capacity,
    this.dogsNow = 0,
    this.working = false,
    this.selected = false,
  });

  factory RoutePlanDriver.fromJson(Map<String, dynamic> json) => RoutePlanDriver(
        staffMemberId: json['staff_member_id'],
        name: json['name'] ?? '',
        vehicleName: json['vehicle_name'],
        capacity: _intOrNull(json['capacity']),
        dogsNow: json['dogs_now'] ?? 0,
        working: json['working'] ?? false,
        selected: json['selected'] ?? false,
      );
}

/// A whole-day suggestion: every driver's dogs, in order.
class RoutePlan {
  final List<PlannedRoute> routes;
  final List<({int dogId, String name, String reason})> unplaced;

  /// Groups of dog names still sharing a van against a compatibility note.
  final List<List<String>> conflicts;

  /// Drivers still carrying more dogs than their van takes.
  final List<String> overCapacity;

  const RoutePlan({
    required this.routes,
    this.unplaced = const [],
    this.conflicts = const [],
    this.overCapacity = const [],
  });

  int get movedCount => routes.fold(0, (n, r) => n + r.dogs.where((d) => d.moved).length);
  int get currentMinutes => routes.fold(0, (n, r) => n + r.currentMinutes);
  int get plannedMinutes => routes.fold(0, (n, r) => n + r.minutes);

  factory RoutePlan.fromJson(Map<String, dynamic> json) => RoutePlan(
        routes: (json['routes'] as List).map((r) => PlannedRoute.fromJson(r)).toList(),
        unplaced: (json['unplaced'] as List? ?? const [])
            .map((u) => (dogId: u['dog_id'] as int, name: (u['name'] ?? '') as String, reason: (u['reason'] ?? '') as String))
            .toList(),
        conflicts: (json['conflicts'] as List? ?? const []).map((g) => (g as List).cast<String>()).toList(),
        overCapacity: (json['over_capacity'] as List? ?? const []).cast<String>(),
      );
}

class PlannedRoute {
  final int staffMemberId;
  final String staffMemberName;
  final int? capacity;
  final int load;
  final int minutes;

  /// The same driver's run as the board stands now.
  final int currentMinutes;
  final List<PlannedDog> dogs;

  const PlannedRoute({
    required this.staffMemberId,
    required this.staffMemberName,
    this.capacity,
    required this.load,
    required this.minutes,
    required this.currentMinutes,
    required this.dogs,
  });

  factory PlannedRoute.fromJson(Map<String, dynamic> json) => PlannedRoute(
        staffMemberId: json['staff_member_id'],
        staffMemberName: json['staff_member_name'] ?? '',
        capacity: _intOrNull(json['capacity']),
        load: json['load'] ?? 0,
        minutes: json['minutes'] ?? 0,
        currentMinutes: json['current_minutes'] ?? 0,
        dogs: (json['dogs'] as List).map((d) => PlannedDog.fromJson(d)).toList(),
      );
}

class PlannedDog {
  final int dogId;
  final String name;
  final bool located;

  /// Already collected or returned: stays with its driver.
  final bool pinned;

  /// Not with this driver on the board now.
  final bool moved;
  final String? fromStaffMemberName;

  const PlannedDog({
    required this.dogId,
    required this.name,
    this.located = true,
    this.pinned = false,
    this.moved = false,
    this.fromStaffMemberName,
  });

  factory PlannedDog.fromJson(Map<String, dynamic> json) => PlannedDog(
        dogId: json['dog_id'],
        name: json['name'] ?? '',
        located: json['located'] ?? true,
        pinned: json['pinned'] ?? false,
        moved: json['moved'] ?? false,
        fromStaffMemberName: json['from_staff_member_name'],
      );
}
