import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/roadwork_issue.dart';

RoadworkIssue issue({
  int id = 1,
  String severity = 'LOW',
  String street = 'Station Road',
  String town = 'Marlow',
  List<int> staffIds = const [10],
  double? lat = 51.5,
  double? lng = -0.8,
}) =>
    RoadworkIssue.fromJson({
      'id': id,
      'description': 'Gas main',
      'street': street,
      'town': town,
      'latitude': lat,
      'longitude': lng,
      'start_date': '2026-08-01',
      'end_date': '2026-08-05',
      'severity': severity,
      'severity_label': 'Road closed',
      'traffic_management': 'road_closure',
      'affected_staff_ids': staffIds,
      'affected_dog_ids': const [1, 2],
    });

void main() {
  group('parsing', () {
    test('reads the API shape', () {
      final i = issue(severity: 'HIGH');
      expect(i.id, 1);
      expect(i.severity, RoadworkSeverity.high);
      expect(i.street, 'Station Road');
      expect(i.affectedStaffIds, [10]);
      expect(i.affectedDogIds, [1, 2]);
      expect(i.hasLocation, isTrue);
      expect(i.startDate, DateTime(2026, 8, 1));
    });

    test('an unknown severity degrades to low rather than crying wolf', () {
      expect(issue(severity: 'CATASTROPHIC').severity, RoadworkSeverity.low);
      expect(issue(severity: '').severity, RoadworkSeverity.low);
    });

    test('tolerates missing optional fields', () {
      final i = RoadworkIssue.fromJson({
        'id': 7,
        'start_date': '2026-08-01',
        'end_date': '2026-08-01',
        'severity': 'MEDIUM',
      });
      expect(i.street, '');
      expect(i.hasLocation, isFalse);
      expect(i.affectedStaffIds, isEmpty);
      expect(i.locationLabel, 'Location unavailable');
    });

    test('numeric coordinates arriving as strings still parse', () {
      final i = RoadworkIssue.fromJson({
        'id': 8,
        'start_date': '2026-08-01',
        'end_date': '2026-08-01',
        'severity': 'LOW',
        'latitude': '51.5',
        'longitude': '-0.8',
      });
      expect(i.latitude, 51.5);
      expect(i.hasLocation, isTrue);
    });
  });

  group('location label', () {
    test('combines street and town, falling back as fields drop out', () {
      expect(issue().locationLabel, 'Station Road, Marlow');
      expect(issue(town: '').locationLabel, 'Station Road');
      expect(issue(street: '').locationLabel, 'Marlow');
    });
  });

  group('per-staff filtering', () {
    final issues = [
      issue(id: 1, severity: 'LOW', staffIds: const [10]),
      issue(id: 2, severity: 'HIGH', staffIds: const [10, 20]),
      issue(id: 3, severity: 'MEDIUM', staffIds: const [20]),
    ];

    test('returns only that route, worst first', () {
      final forTen = issues.forStaff(10);
      expect(forTen.map((i) => i.id), [2, 1]);
    });

    test('worst severity drives the ring colour', () {
      expect(issues.worstForStaff(10), RoadworkSeverity.high);
      expect(issues.worstForStaff(20), RoadworkSeverity.high);
      expect(issues.worstForStaff(30), isNull);
    });

    test('a null staff id matches nothing', () {
      // The dashboard groups by a nullable staff id; unassigned must not
      // silently inherit someone else's roadworks.
      expect(issues.forStaff(null), isEmpty);
      expect(issues.worstForStaff(null), isNull);
    });

    test('collects every affected staff id', () {
      expect(issues.affectedStaffIds, {10, 20});
    });
  });
}
