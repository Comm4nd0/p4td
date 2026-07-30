/// How much a roadwork is expected to cost a driver. Ordered worst-first so a
/// route's overall state is just the minimum of its issues.
enum RoadworkSeverity {
  high,
  medium,
  low;

  static RoadworkSeverity fromApi(String? value) {
    switch ((value ?? '').toUpperCase()) {
      case 'HIGH':
        return RoadworkSeverity.high;
      case 'MEDIUM':
        return RoadworkSeverity.medium;
      default:
        return RoadworkSeverity.low;
    }
  }

  /// Lower sorts first / is worse.
  int get rank => switch (this) {
        RoadworkSeverity.high => 0,
        RoadworkSeverity.medium => 1,
        RoadworkSeverity.low => 2,
      };
}

/// A road closure or street works in force on a given day, already matched by
/// the server to the staff routes it disrupts.
class RoadworkIssue {
  final int id;
  final String description;
  final String street;
  final String town;
  final double? latitude;
  final double? longitude;
  final DateTime startDate;
  final DateTime endDate;
  final RoadworkSeverity severity;

  /// Server-provided wording for the severity, e.g. "Road closed".
  final String severityLabel;

  /// Raw traffic management type from the feed, e.g. `two-way signals`.
  final String trafficManagement;

  final List<int> affectedStaffIds;
  final List<int> affectedDogIds;

  const RoadworkIssue({
    required this.id,
    required this.description,
    required this.street,
    required this.town,
    required this.startDate,
    required this.endDate,
    required this.severity,
    required this.severityLabel,
    required this.trafficManagement,
    required this.affectedStaffIds,
    required this.affectedDogIds,
    this.latitude,
    this.longitude,
  });

  bool get hasLocation => latitude != null && longitude != null;

  /// Best short name for the place, falling back through the fields the feed
  /// may or may not populate.
  String get locationLabel {
    if (street.isNotEmpty && town.isNotEmpty) return '$street, $town';
    if (street.isNotEmpty) return street;
    if (town.isNotEmpty) return town;
    return 'Location unavailable';
  }

  bool affectsStaff(int? staffId) =>
      staffId != null && affectedStaffIds.contains(staffId);

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse('$value');
  }

  static DateTime _toDate(dynamic value) =>
      DateTime.tryParse('$value') ?? DateTime.now();

  static List<int> _toIntList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((e) => e is int ? e : int.tryParse('$e'))
        .whereType<int>()
        .toList();
  }

  factory RoadworkIssue.fromJson(Map<String, dynamic> json) => RoadworkIssue(
        id: json['id'] as int,
        description: (json['description'] ?? '') as String,
        street: (json['street'] ?? '') as String,
        town: (json['town'] ?? '') as String,
        latitude: _toDouble(json['latitude']),
        longitude: _toDouble(json['longitude']),
        startDate: _toDate(json['start_date']),
        endDate: _toDate(json['end_date']),
        severity: RoadworkSeverity.fromApi(json['severity'] as String?),
        severityLabel: (json['severity_label'] ?? '') as String,
        trafficManagement: (json['traffic_management'] ?? '') as String,
        affectedStaffIds: _toIntList(json['affected_staff_ids']),
        affectedDogIds: _toIntList(json['affected_dog_ids']),
      );
}

/// Convenience helpers over a day's worth of issues.
extension RoadworkIssueList on List<RoadworkIssue> {
  /// Only the issues touching one staff member's route, worst first.
  List<RoadworkIssue> forStaff(int? staffId) {
    final matched = where((i) => i.affectsStaff(staffId)).toList()
      ..sort((a, b) => a.severity.rank.compareTo(b.severity.rank));
    return matched;
  }

  /// The worst severity on a staff member's route, or null if it's clear.
  RoadworkSeverity? worstForStaff(int? staffId) {
    final matched = forStaff(staffId);
    return matched.isEmpty ? null : matched.first.severity;
  }

  /// Every staff id with at least one issue today.
  Set<int> get affectedStaffIds =>
      expand((i) => i.affectedStaffIds).toSet();
}
