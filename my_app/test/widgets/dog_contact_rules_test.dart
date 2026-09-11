import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/widgets/dog_contact_rules.dart';

void main() {
  group('dog contact rules', () {
    test('lists the blank client-required fields in form order', () {
      expect(
        missingDogContactFields(contactNumber: '', emergencyContactNumber: ' '),
        ['Contact number', 'Emergency contact number'],
      );
      expect(
        missingDogContactFields(contactNumber: '07700 900123', emergencyContactNumber: ''),
        ['Emergency contact number'],
      );
      expect(
        missingDogContactFields(contactNumber: '07700 900123', emergencyContactNumber: '07700 900456'),
        isEmpty,
      );
    });

    test('a client is stopped by a blank number, staff never are', () {
      expect(dogContactValidator('', isStaff: false), 'Required');
      expect(dogContactValidator('  ', isStaff: false), 'Required');
      expect(dogContactValidator(null, isStaff: false), 'Required');
      expect(dogContactValidator('07700 900123', isStaff: false), isNull);
      expect(dogContactValidator('', isStaff: true), isNull);
      expect(dogContactValidator(null, isStaff: true), isNull);
    });
  });
}
