import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/date_change_request.dart';

Map<String, dynamic> _json({Map<String, dynamic>? extra}) => {
      'id': 7,
      'dog': 3,
      'dog_name': 'Fido',
      'owner_name': 'Sam',
      'request_type': 'ADD_DAY',
      'original_date': null,
      'new_date': '2026-09-21',
      'status': 'PENDING',
      'is_charged': false,
      'created_at': '2026-09-13T10:00:00Z',
      ...?extra,
    };

void main() {
  group('DateChangeRequest.fromJson', () {
    test('parses the dog picture and the new-date summary', () {
      final req = DateChangeRequest.fromJson(_json(extra: {
        'dog_profile_image': 'https://example.com/media/dog_profiles/fido.jpg',
        'new_date_summary': {
          'date': '2026-09-21',
          'dogs_booked': 12,
          'capacity': 20,
          'staff_working': 3,
          'staff_names': ['Alice', 'Bob', 'Carol'],
        },
      }));

      expect(req.dogProfileImage, 'https://example.com/media/dog_profiles/fido.jpg');
      final summary = req.newDateSummary!;
      expect(summary.date, DateTime(2026, 9, 21));
      expect(summary.dogsBooked, 12);
      expect(summary.capacity, 20);
      expect(summary.staffWorking, 3);
      expect(summary.staffNames, ['Alice', 'Bob', 'Carol']);
      expect(summary.isFull, isFalse);
      expect(summary.dogsLabel, '12 of 20 dogs booked');
      expect(summary.staffLabel, '3 staff working');
    });

    test('tolerates a missing picture and summary (owner responses, old servers)', () {
      final req = DateChangeRequest.fromJson(_json());
      expect(req.dogProfileImage, isNull);
      expect(req.newDateSummary, isNull);

      final explicitNull = DateChangeRequest.fromJson(
          _json(extra: {'dog_profile_image': null, 'new_date_summary': null}));
      expect(explicitNull.newDateSummary, isNull);
    });

    test('summary without a capacity limit is never full', () {
      final req = DateChangeRequest.fromJson(_json(extra: {
        'new_date_summary': {
          'date': '2026-09-21',
          'dogs_booked': 1,
          'capacity': null,
          'staff_working': 0,
          'staff_names': [],
        },
      }));
      final summary = req.newDateSummary!;
      expect(summary.capacity, isNull);
      expect(summary.isFull, isFalse);
      expect(summary.dogsLabel, '1 dog booked');
      expect(summary.staffNames, isEmpty);
    });

    test('a full day is flagged', () {
      final req = DateChangeRequest.fromJson(_json(extra: {
        'new_date_summary': {
          'date': '2026-09-21',
          'dogs_booked': 20,
          'capacity': 20,
          'staff_working': 2,
          'staff_names': ['Alice', 'Bob'],
        },
      }));
      expect(req.newDateSummary!.isFull, isTrue);
    });
  });
}
