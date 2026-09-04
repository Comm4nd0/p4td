import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/vaccination_certificate.dart';
import 'package:paws4thoughtdogs/widgets/vaccination_certificate_tile.dart';

void main() {
  VaccinationCertificate cert({String name = 'vax-card.pdf', String type = 'application/pdf', DateTime? date, String? by = 'Alex'}) =>
      VaccinationCertificate(
        id: 1,
        dogId: '7',
        dogName: 'Biscuit',
        vaccinationDate: date,
        originalFilename: name,
        contentType: type,
        sizeBytes: 348160,
        uploadedByName: by,
        downloadUrl: '/api/vaccination-certificates/1/download/',
        createdAt: DateTime(2026, 3, 13),
      );

  testWidgets('describes the certificate: name, date, size, who', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VaccinationCertificateTile(certificate: cert(date: DateTime(2026, 3, 12))),
      ),
    ));
    expect(find.text('vax-card.pdf'), findsOneWidget);
    expect(find.text('Vaccinated 12/03/2026 · 340 KB · added by Alex'), findsOneWidget);
  });

  testWidgets('leaves out what it does not know', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VaccinationCertificateTile(certificate: cert(name: '', type: 'image/jpeg', by: null)),
      ),
    ));
    expect(find.text('Certificate photo'), findsOneWidget);
    expect(find.text('340 KB'), findsOneWidget);
  });

  testWidgets('tap reaches the callback', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VaccinationCertificateTile(certificate: cert(), onTap: () => taps++),
      ),
    ));
    await tester.tap(find.text('vax-card.pdf'));
    expect(taps, 1);
  });
}
