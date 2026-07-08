import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:paws4thoughtdogs/screens/enquiry_screen.dart';
import 'package:paws4thoughtdogs/services/enquiry_service.dart';
import 'package:paws4thoughtdogs/services/no_connection_exception.dart';

class _StubEnquiryService extends EnquiryService {
  /// Returned from submitEnquiry (null = success).
  String? result;
  bool throwNoConnection = false;
  Map<String, String>? lastSubmission;

  @override
  Future<String?> submitEnquiry({
    required String name,
    required String email,
    required String service,
    required String message,
  }) async {
    if (throwNoConnection) throw const NoConnectionException();
    lastSubmission = {
      'name': name,
      'email': email,
      'service': service,
      'message': message,
    };
    return result;
  }
}

void main() {
  late _StubEnquiryService stub;

  setUp(() => stub = _StubEnquiryService());

  /// Pushes the screen onto a host route so a successful submit can pop.
  Future<void> pumpEnquiry(WidgetTester tester, {String? initialService}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => EnquiryScreen(
                  initialService: initialService,
                  enquiryService: stub,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> fillValidForm(WidgetTester tester) async {
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Jane Prospect');
    await tester.enterText(fields.at(1), 'jane@example.com');
    await tester.enterText(fields.at(2), 'Do you have space on Tuesdays?');
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Send Message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send Message'));
    await tester.pumpAndSettle();
  }

  testWidgets('empty form shows validation errors and does not submit',
      (tester) async {
    await pumpEnquiry(tester);
    await submit(tester);

    expect(find.text('Required'), findsNWidgets(3));
    expect(stub.lastSubmission, isNull);
  });

  testWidgets('invalid email is rejected client-side', (tester) async {
    await pumpEnquiry(tester);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Jane');
    await tester.enterText(fields.at(1), 'not-an-email');
    await tester.enterText(fields.at(2), 'Hello');
    await submit(tester);

    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(stub.lastSubmission, isNull);
  });

  testWidgets('initialService pre-selects the dropdown and is submitted',
      (tester) async {
    await pumpEnquiry(tester, initialService: 'field_hire');
    expect(find.text('Field Hire'), findsOneWidget);

    await fillValidForm(tester);
    await submit(tester);
    expect(stub.lastSubmission?['service'], 'field_hire');
  });

  testWidgets('successful submit pops and shows a confirmation snackbar',
      (tester) async {
    await pumpEnquiry(tester);
    await fillValidForm(tester);
    await submit(tester);

    expect(find.byType(EnquiryScreen), findsNothing);
    expect(find.textContaining('Your message has been sent'), findsOneWidget);
  });

  testWidgets('server error message is shown and the form is kept',
      (tester) async {
    stub.result =
        'You have sent several messages recently. Please try again later.';
    await pumpEnquiry(tester);
    await fillValidForm(tester);
    await submit(tester);

    expect(find.byType(EnquiryScreen), findsOneWidget);
    expect(find.textContaining('sent several messages'), findsOneWidget);
    // Typed content survives the failed attempt.
    expect(find.text('Jane Prospect'), findsOneWidget);
  });

  testWidgets('offline submit shows a connection error and keeps the form',
      (tester) async {
    stub.throwNoConnection = true;
    await pumpEnquiry(tester);
    await fillValidForm(tester);
    await submit(tester);

    expect(find.byType(EnquiryScreen), findsOneWidget);
    expect(find.textContaining('No internet connection'), findsOneWidget);
    expect(find.text('Jane Prospect'), findsOneWidget);
  });
}
