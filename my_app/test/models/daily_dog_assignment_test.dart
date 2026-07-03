import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';

void main() {
  DailyDogAssignment make({
    bool isBoarding = false,
    bool firstDay = false,
    bool lastDay = false,
    bool ownerBrings = false,
    bool ownerCollects = false,
  }) {
    return DailyDogAssignment(
      id: 1,
      dogId: 1,
      dogName: 'Rex',
      staffMemberId: 7,
      staffMemberName: 'Sarah',
      ownerName: 'Owner',
      date: DateTime(2030, 6, 1),
      status: AssignmentStatus.assigned,
      isBoarding: isBoarding,
      isBoardingFirstDay: firstDay,
      isBoardingLastDay: lastDay,
      effectiveOwnerBrings: ownerBrings,
      effectiveOwnerCollects: ownerCollects,
    );
  }

  group('boarding transport legs', () {
    test('non-boarding staff-transported dog needs both legs', () {
      final a = make();
      expect(a.needsPickup, isTrue);
      expect(a.needsDropoff, isTrue);
      expect(a.noStaffTransport, isFalse);
    });

    test('first day of boarding: pickup only, stays overnight', () {
      final a = make(isBoarding: true, firstDay: true);
      expect(a.needsPickup, isTrue);
      expect(a.needsDropoff, isFalse);
      expect(a.noStaffTransport, isFalse);
    });

    test('mid-boarding: no transport at all', () {
      final a = make(isBoarding: true);
      expect(a.needsPickup, isFalse);
      expect(a.needsDropoff, isFalse);
      expect(a.noStaffTransport, isTrue);
    });

    test('last day of boarding: drop home only, no morning pickup', () {
      final a = make(isBoarding: true, lastDay: true);
      expect(a.needsPickup, isFalse);
      expect(a.needsDropoff, isTrue);
      expect(a.noStaffTransport, isFalse);
    });

    test('single-day boarding behaves like a normal day', () {
      final a = make(isBoarding: true, firstDay: true, lastDay: true);
      expect(a.needsPickup, isTrue);
      expect(a.needsDropoff, isTrue);
    });

    test('owner-handled legs stay owner-handled on boarding edge days', () {
      final first = make(
          isBoarding: true, firstDay: true, ownerBrings: true, ownerCollects: true);
      expect(first.needsPickup, isFalse);
      expect(first.needsDropoff, isFalse);
      expect(first.noStaffTransport, isTrue);

      final last = make(
          isBoarding: true, lastDay: true, ownerBrings: true, ownerCollects: true);
      expect(last.needsPickup, isFalse);
      expect(last.needsDropoff, isFalse);
    });

    test('owner brings but staff take home: dropoff still suppressed mid-stay', () {
      final a = make(isBoarding: true, ownerBrings: true);
      expect(a.needsPickup, isFalse);
      expect(a.needsDropoff, isFalse);
    });
  });

  group('boardingLabel', () {
    test('is empty for non-boarding dogs', () {
      expect(make().boardingLabel, isEmpty);
    });

    test('describes each stage of the stay', () {
      expect(make(isBoarding: true, firstDay: true, lastDay: true).boardingLabel,
          'Boarding');
      expect(make(isBoarding: true, firstDay: true).boardingLabel,
          contains('staying overnight'));
      expect(make(isBoarding: true, lastDay: true).boardingLabel,
          contains('going home'));
      expect(make(isBoarding: true).boardingLabel, contains('with staff'));
    });
  });

  group('fromJson', () {
    test('parses the boarding edge-day fields', () {
      final a = DailyDogAssignment.fromJson({
        'id': 1,
        'dog': 2,
        'staff_member': 3,
        'date': '2030-06-01',
        'is_boarding': true,
        'boarding_first_day': true,
        'boarding_last_day': false,
      });
      expect(a.isBoarding, isTrue);
      expect(a.isBoardingFirstDay, isTrue);
      expect(a.isBoardingLastDay, isFalse);
      expect(a.needsPickup, isTrue);
      expect(a.needsDropoff, isFalse);
    });

    test('missing edge-day fields keep the old both-legs behaviour', () {
      final a = DailyDogAssignment.fromJson({
        'id': 1,
        'dog': 2,
        'staff_member': 3,
        'date': '2030-06-01',
        'is_boarding': true,
      });
      expect(a.needsPickup, isTrue);
      expect(a.needsDropoff, isTrue);
    });
  });
}
