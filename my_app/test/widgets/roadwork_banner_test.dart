import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/roadwork_issue.dart';
import 'package:paws4thoughtdogs/widgets/roadwork_banner.dart';

RoadworkIssue issue({
  int id = 1,
  String severity = 'HIGH',
  String street = 'Station Road',
  String description = 'Gas main replacement',
}) =>
    RoadworkIssue.fromJson({
      'id': id,
      'description': description,
      'street': street,
      'town': 'Marlow',
      'latitude': 51.5,
      'longitude': -0.8,
      'start_date': '2026-08-01',
      'end_date': '2026-08-05',
      'severity': severity,
      'severity_label': severity == 'HIGH' ? 'Road closed' : 'Delays likely',
      'traffic_management': 'road_closure',
      'affected_staff_ids': const [10],
      'affected_dog_ids': const [1],
    });

Future<void> pump(WidgetTester tester, List<RoadworkIssue> issues) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(body: RoadworkBanner(issues: issues)),
    ));

void main() {
  testWidgets('a clear route shows nothing at all', (tester) async {
    await pump(tester, const []);

    // Not an "all clear" row — that would be noise on every ordinary day.
    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('roadwork'), findsNothing);
  });

  testWidgets('lists each issue with its location and detail', (tester) async {
    await pump(tester, [
      issue(id: 1, street: 'Station Road'),
      issue(id: 2, street: 'Mill Lane', severity: 'MEDIUM'),
    ]);

    expect(find.text('2 roadworks on this route'), findsOneWidget);
    expect(find.text('Station Road, Marlow'), findsOneWidget);
    expect(find.text('Mill Lane, Marlow'), findsOneWidget);
    expect(find.textContaining('Road closed'), findsOneWidget);
  });

  testWidgets('singular wording for one issue', (tester) async {
    await pump(tester, [issue()]);
    expect(find.text('1 roadwork on this route'), findsOneWidget);
  });

  testWidgets('the border takes the worst severity colour', (tester) async {
    await pump(tester, [issue(severity: 'HIGH')]);

    final card = tester.widget<Card>(find.byType(Card));
    final shape = card.shape as RoundedRectangleBorder;
    expect(shape.side.color, roadworkSeverityColor(RoadworkSeverity.high));
  });

  testWidgets('an issue with no description still renders its location',
      (tester) async {
    await pump(tester, [issue(description: '')]);
    expect(find.text('Station Road, Marlow'), findsOneWidget);
  });

  testWidgets('severity colours are distinct', (tester) async {
    final colours = {
      roadworkSeverityColor(RoadworkSeverity.high),
      roadworkSeverityColor(RoadworkSeverity.medium),
      roadworkSeverityColor(RoadworkSeverity.low),
    };
    expect(colours, hasLength(3));
  });
}
