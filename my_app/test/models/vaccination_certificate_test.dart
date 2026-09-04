import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/vaccination_certificate.dart';

void main() {
  Map<String, dynamic> json({String contentType = 'application/pdf', int size = 348160}) => {
        'id': 12,
        'dog': 7,
        'dog_name': 'Biscuit',
        'vaccination_date': '2026-03-12',
        'original_filename': 'vax-card.pdf',
        'content_type': contentType,
        'size_bytes': size,
        'uploaded_by': 3,
        'uploaded_by_name': 'Alex',
        'download_url': 'https://example.test/api/vaccination-certificates/12/download/',
        'created_at': '2026-03-13T09:15:00Z',
      };

  group('VaccinationCertificate.fromJson', () {
    test('parses the API payload', () {
      final c = VaccinationCertificate.fromJson(json());
      expect(c.id, 12);
      expect(c.dogId, '7');
      expect(c.dogName, 'Biscuit');
      expect(c.vaccinationDate, DateTime(2026, 3, 12));
      expect(c.originalFilename, 'vax-card.pdf');
      expect(c.uploadedById, 3);
      expect(c.uploadedByName, 'Alex');
      expect(c.downloadUrl, endsWith('/12/download/'));
      expect(c.isPdf, isTrue);
      expect(c.isImage, isFalse);
      expect(c.fileExtension, 'pdf');
    });

    test('there is never a file URL — only the gated download URL', () {
      // The API marks `file` write-only. If a payload ever carried it, the
      // model must not pick it up: nothing in the app may fetch by path.
      final c = VaccinationCertificate.fromJson({...json(), 'file': '/private-media/x.pdf'});
      expect(c.downloadUrl, isNot(contains('private-media')));
    });

    test('tolerates missing optional fields', () {
      final c = VaccinationCertificate.fromJson({
        'id': 1,
        'dog': 2,
        'content_type': 'image/jpeg',
        'created_at': '2026-01-01T00:00:00Z',
      });
      expect(c.vaccinationDate, isNull);
      expect(c.originalFilename, '');
      expect(c.displayName, 'Certificate photo');
      expect(c.uploadedById, isNull);
      expect(c.sizeBytes, 0);
      expect(c.isImage, isTrue);
      expect(c.fileExtension, 'jpg');
    });
  });

  group('sizeLabel', () {
    test('kilobytes under a megabyte, megabytes above', () {
      expect(VaccinationCertificate.fromJson(json(size: 348160)).sizeLabel, '340 KB');
      expect(VaccinationCertificate.fromJson(json(size: 2202009)).sizeLabel, '2.1 MB');
    });
  });

  group('canBeRemovedBy', () {
    final c = VaccinationCertificate.fromJson(json());

    test('staff always can', () {
      expect(c.canBeRemovedBy(userId: 99, isStaff: true), isTrue);
      expect(c.canBeRemovedBy(userId: null, isStaff: true), isTrue);
    });

    test('an owner only if they uploaded it', () {
      expect(c.canBeRemovedBy(userId: 3, isStaff: false), isTrue);
      expect(c.canBeRemovedBy(userId: 4, isStaff: false), isFalse);
      expect(c.canBeRemovedBy(userId: null, isStaff: false), isFalse);
    });
  });
}
