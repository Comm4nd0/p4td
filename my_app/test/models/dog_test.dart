import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/dog.dart';

void main() {
  group('parseDogSex / dogSexToApi', () {
    test('parses backend M/F codes', () {
      expect(parseDogSex('M'), DogSex.male);
      expect(parseDogSex('F'), DogSex.female);
      expect(parseDogSex('m'), DogSex.male);
      expect(parseDogSex('f'), DogSex.female);
    });

    test('returns null for unknown or null values', () {
      expect(parseDogSex(null), isNull);
      expect(parseDogSex(''), isNull);
      expect(parseDogSex('X'), isNull);
    });

    test('round-trips through the API representation', () {
      expect(dogSexToApi(DogSex.male), 'M');
      expect(dogSexToApi(DogSex.female), 'F');
      expect(dogSexToApi(null), isNull);
      expect(parseDogSex(dogSexToApi(DogSex.female)), DogSex.female);
    });
  });

  group('parseApiDate / formatApiDate', () {
    test('parses ISO date strings', () {
      final d = parseApiDate('2024-03-09');
      expect(d, isNotNull);
      expect(d!.year, 2024);
      expect(d.month, 3);
      expect(d.day, 9);
    });

    test('returns null for empty/null', () {
      expect(parseApiDate(null), isNull);
      expect(parseApiDate(''), isNull);
    });

    test('formats with zero-padding', () {
      expect(formatApiDate(DateTime(2024, 1, 5)), '2024-01-05');
      expect(formatApiDate(null), isNull);
    });
  });

  group('parseApiTime / formatApiTime', () {
    test('parses HH:MM and HH:MM:SS', () {
      expect(parseApiTime('15:30'), const TimeOfDay(hour: 15, minute: 30));
      expect(parseApiTime('09:05:00'), const TimeOfDay(hour: 9, minute: 5));
    });

    test('returns null for malformed input', () {
      expect(parseApiTime(null), isNull);
      expect(parseApiTime('nonsense'), isNull);
    });

    test('formats with zero-padding', () {
      expect(formatApiTime(const TimeOfDay(hour: 9, minute: 5)), '09:05');
    });
  });

  group('DropoffTime', () {
    test('round-trips api values', () {
      expect(DropoffTime.after1530.apiValue, 'after_1530');
      expect(DropoffTime.after1600.apiValue, 'after_1600');
      expect(DropoffTimeExtension.fromApiValue('after_1530'), DropoffTime.after1530);
      expect(DropoffTimeExtension.fromApiValue('bogus'), isNull);
    });
  });

  group('ScheduleType', () {
    test('round-trips api values and defaults to weekly', () {
      expect(ScheduleType.fortnightly.apiValue, 'fortnightly');
      expect(ScheduleType.adHoc.apiValue, 'ad_hoc');
      expect(ScheduleTypeExtension.fromApiValue('ad_hoc'), ScheduleType.adHoc);
      expect(ScheduleTypeExtension.fromApiValue(null), ScheduleType.weekly);
      expect(ScheduleTypeExtension.fromApiValue('unknown'), ScheduleType.weekly);
    });
  });

  group('Weekday', () {
    test('dayNumber is Monday=1..Friday=5', () {
      expect(Weekday.monday.dayNumber, 1);
      expect(Weekday.friday.dayNumber, 5);
    });

    test('displayName capitalises', () {
      expect(Weekday.wednesday.displayName, 'Wednesday');
    });
  });

  group('Dog', () {
    Dog buildDog({DogSex? sex, bool isSpayed = false, DateTime? dob}) => Dog(
          id: '1',
          name: 'Rex',
          ownerId: '7',
          sex: sex,
          isSpayed: isSpayed,
          dateOfBirth: dob,
        );

    test('needsSpayPrompt only for intact males over a year old', () {
      final old = DateTime.now().subtract(const Duration(days: 400));
      final young = DateTime.now().subtract(const Duration(days: 100));

      expect(buildDog(sex: DogSex.male, dob: old).needsSpayPrompt, isTrue);
      expect(buildDog(sex: DogSex.male, isSpayed: true, dob: old).needsSpayPrompt, isFalse);
      expect(buildDog(sex: DogSex.female, dob: old).needsSpayPrompt, isFalse);
      expect(buildDog(sex: DogSex.male, dob: young).needsSpayPrompt, isFalse);
      expect(buildDog(sex: DogSex.male, dob: null).needsSpayPrompt, isFalse);
    });

    test('allOwners combines primary and additional owners in order', () {
      final primary = OwnerDetails(userId: 1, username: 'a', email: 'a@x.com');
      final extra = OwnerDetails(userId: 2, username: 'b', email: 'b@x.com');
      final dog = Dog(
        id: '1',
        name: 'Rex',
        ownerId: '1',
        ownerDetails: primary,
        additionalOwners: [extra],
      );
      expect(dog.allOwners.map((o) => o.userId), [1, 2]);

      final noPrimary = Dog(id: '2', name: 'Bo', ownerId: '0', additionalOwners: [extra]);
      expect(noPrimary.allOwners.map((o) => o.userId), [2]);
    });

    test('copyWith overrides only the provided fields', () {
      final dog = buildDog(sex: DogSex.male);
      final updated = dog.copyWith(name: 'Buddy', isSpayed: true);
      expect(updated.name, 'Buddy');
      expect(updated.isSpayed, isTrue);
      expect(updated.id, dog.id);
      expect(updated.sex, DogSex.male);
    });
  });
}
