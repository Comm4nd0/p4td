import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/invoice.dart';
import 'package:paws4thoughtdogs/screens/customer_payments_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

class _PaymentsFakeDataService extends MockDataService {
  final List<(int?, int?)> invoiceFetches = [];
  Completer<List<Invoice>>? hold;

  @override
  Future<List<Invoice>> getInvoices({int? year, int? month, String? status, int? customerId}) {
    invoiceFetches.add((year, month));
    final held = hold;
    if (held != null) return held.future;
    return Future.value(<Invoice>[]);
  }
}

Future<void> _pump(WidgetTester tester, DataService fake) async {
  if (getIt.isRegistered<DataService>()) {
    getIt.unregister<DataService>();
  }
  getIt.registerSingleton<DataService>(fake);
  addTearDown(() => getIt.unregister<DataService>());
  await tester.pumpWidget(MaterialApp(
    home: CustomerPaymentsScreen(now: DateTime(2026, 11, 1, 9)),
  ));
}

IconButton _arrow(WidgetTester tester, String tooltip) => tester.widget<IconButton>(
    find.widgetWithIcon(IconButton, tooltip == 'Next month' ? Icons.chevron_right : Icons.chevron_left));

void main() {
  testWidgets('opens on the current month — billing is in advance', (tester) async {
    final fake = _PaymentsFakeDataService();
    await _pump(tester, fake);
    await tester.pumpAndSettle();

    // On the 1st the drafts just raised are November's; this used to open
    // on October.
    expect(find.text('November 2026'), findsOneWidget);
    expect(fake.invoiceFetches.single, (2026, 11));
  });

  testWidgets('the month arrows wait for the month on screen to load', (tester) async {
    final fake = _PaymentsFakeDataService()..hold = Completer<List<Invoice>>();
    await _pump(tester, fake);
    await tester.pump();

    expect(_arrow(tester, 'Next month').onPressed, isNull);
    expect(_arrow(tester, 'Previous month').onPressed, isNull);

    fake.hold!.complete(<Invoice>[]);
    fake.hold = null;
    await tester.pumpAndSettle();

    expect(_arrow(tester, 'Next month').onPressed, isNotNull);
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.text('October 2026'), findsOneWidget);
    expect(fake.invoiceFetches.last, (2026, 10));
  });
}
