import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/screens/dashboard/action_items_section.dart';

/// The dashboard's action items group related things into one row: site and
/// vehicle defects under "Defects", and neutered status + overdue
/// vaccinations under "Dog health to confirm".
void main() {
  Widget build({
    int siteDefects = 0,
    int vehicleDefects = 0,
    int dogHealth = 0,
    VoidCallback? onOpenDefects,
    VoidCallback? onOpenDogHealth,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ActionItemsSection(
            pendingRequestCount: 0,
            unresolvedQueryCount: 0,
            unreadInquiryCount: 0,
            pendingProfileChangeCount: 0,
            pendingBoardingCount: 0,
            unresolvedDefectCount: siteDefects,
            unresolvedVehicleDefectCount: vehicleDefects,
            openIncidentCount: 0,
            dogHealthCount: dogHealth,
            canViewInquiries: false,
            canManageRequests: false,
            onOpenPendingRequests: () {},
            onOpenQueries: () {},
            onOpenInquiries: () {},
            onOpenProfileChanges: () {},
            onOpenBoardingRequests: () {},
            onOpenDefects: onOpenDefects ?? () {},
            onOpenIncidents: () {},
            onOpenDogHealth: onOpenDogHealth ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('defects are one row with the split in the subtitle', (tester) async {
    await tester.pumpWidget(build(siteDefects: 2, vehicleDefects: 1));
    expect(find.text('Defects'), findsOneWidget);
    expect(find.text('Site Defects'), findsNothing);
    expect(find.text('Vehicle Defects'), findsNothing);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2 site · 1 vehicle'), findsOneWidget);
  });

  testWidgets('no defects means no breakdown line', (tester) async {
    await tester.pumpWidget(build());
    expect(find.text('Defects'), findsOneWidget);
    expect(find.textContaining('site ·'), findsNothing);
  });

  testWidgets('tapping defects fires the grouped callback', (tester) async {
    var opened = 0;
    await tester.pumpWidget(build(siteDefects: 1, onOpenDefects: () => opened++));
    await tester.tap(find.text('Defects'));
    expect(opened, 1);
  });

  testWidgets('dog health row only appears when there is something to confirm', (tester) async {
    await tester.pumpWidget(build());
    expect(find.text('Dog health to confirm'), findsNothing);
    expect(find.text('Neutered status to confirm'), findsNothing);

    var opened = 0;
    await tester.pumpWidget(build(dogHealth: 4, onOpenDogHealth: () => opened++));
    expect(find.text('Dog health to confirm'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    await tester.tap(find.text('Dog health to confirm'));
    expect(opened, 1);
  });
}
