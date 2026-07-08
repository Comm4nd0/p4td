import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:paws4thoughtdogs/screens/enquiry_screen.dart';
import 'package:paws4thoughtdogs/screens/landing_screen.dart';

void main() {
  Future<void> pumpLanding(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LandingScreen()));
  }

  testWidgets('landing page shows public contact details', (tester) async {
    await pumpLanding(tester);

    expect(find.text('Get in Touch'), findsOneWidget);
    expect(find.text('07966 184948'), findsOneWidget);
    expect(find.textContaining('Mon–Fri 8:00 – 17:00'), findsOneWidget);
    expect(find.text('Berkshire & Buckinghamshire, UK'), findsOneWidget);
    expect(find.text('Find us on Facebook'), findsOneWidget);
    expect(find.text('Send Us a Message'), findsOneWidget);
  });

  testWidgets('tapping a service card opens its detail sheet', (tester) async {
    await pumpLanding(tester);

    await tester.ensureVisible(find.text('Day Care'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day Care'));
    await tester.pumpAndSettle();

    // Copy that only exists in the detail sheet.
    expect(find.textContaining('full programme of play'), findsOneWidget);
    expect(find.text('Pick-up and drop-off service available'), findsOneWidget);
    expect(find.text('Make an Enquiry'), findsOneWidget);
  });

  testWidgets('detail sheet enquiry button opens pre-selected form',
      (tester) async {
    await pumpLanding(tester);

    await tester.ensureVisible(find.text('Field Hire'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Field Hire'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make an Enquiry'));
    await tester.pumpAndSettle();

    expect(find.byType(EnquiryScreen), findsOneWidget);
    // Dropdown pre-selected to the tapped service.
    expect(find.text('Field Hire'), findsWidgets);
  });

  testWidgets('Send Us a Message opens the enquiry form', (tester) async {
    await pumpLanding(tester);

    await tester.ensureVisible(find.text('Send Us a Message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send Us a Message'));
    await tester.pumpAndSettle();

    expect(find.byType(EnquiryScreen), findsOneWidget);
    expect(find.text('Your Name'), findsOneWidget);
  });
}
