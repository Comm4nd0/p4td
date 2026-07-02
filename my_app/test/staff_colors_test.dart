import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/constants/pickup_map.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';

void main() {
  group('staffColor', () {
    final ordered = [3, 7, 12, 20];

    test('is deterministic for the same inputs', () {
      expect(staffColor(7, ordered), staffColor(7, ordered));
    });

    test('assigns distinct palette slots by sorted position', () {
      expect(staffColor(3, ordered), kStaffPalette[0]);
      expect(staffColor(7, ordered), kStaffPalette[1]);
      expect(staffColor(12, ordered), kStaffPalette[2]);
      expect(staffColor(20, ordered), kStaffPalette[3]);
    });

    test('stays stable when an unrelated later staff id is added', () {
      final grown = [3, 7, 12, 20, 25];
      // Ids before the insertion point keep their colour.
      expect(staffColor(3, grown), staffColor(3, ordered));
      expect(staffColor(7, grown), staffColor(7, ordered));
    });

    test('wraps around the palette when there are more staff than colours', () {
      final many = List<int>.generate(kStaffPalette.length + 2, (i) => i + 1);
      expect(staffColor(many[kStaffPalette.length], many), kStaffPalette[0]);
      expect(staffColor(many[kStaffPalette.length + 1], many), kStaffPalette[1]);
    });

    test('falls back to a colour for an id not in the ordered list', () {
      // Should not throw and should return a palette colour.
      final c = staffColor(999, ordered);
      expect(kStaffPalette.contains(c), isTrue);
    });

    test('a custom colour always wins over the palette slot', () {
      const chosen = Color(0xFF123456);
      expect(staffColor(7, ordered, custom: const {7: chosen}), chosen);
      // Other members keep their automatic slots.
      expect(staffColor(3, ordered, custom: const {7: chosen}), kStaffPalette[0]);
    });
  });

  group('parseStaffColorHex', () {
    test('parses #RRGGBB into an opaque colour', () {
      expect(parseStaffColorHex('#E53935'), const Color(0xFFE53935));
      expect(parseStaffColorHex('#e53935'), const Color(0xFFE53935));
    });

    test('returns null for blank or malformed values', () {
      expect(parseStaffColorHex(null), isNull);
      expect(parseStaffColorHex(''), isNull);
      expect(parseStaffColorHex('red'), isNull);
      expect(parseStaffColorHex('#12345'), isNull);
      expect(parseStaffColorHex('E53935'), isNull);
    });
  });

  group('StaffColorResolver', () {
    test('uses chosen colours where set and palette slots elsewhere', () {
      final resolver = StaffColorResolver([
        {'id': 7, 'username': 'sarah', 'staff_color': '#112233'},
        {'id': 3, 'username': 'james', 'staff_color': ''},
      ]);
      expect(resolver.of(7), const Color(0xFF112233));
      expect(resolver.of(3), staffColor(3, [3, 7]));
    });
  });

  group('pickupRunNumbers', () {
    DailyDogAssignment make(int id, int staffId, String dog, int sortOrder,
        {bool ownerBoth = false}) {
      return DailyDogAssignment(
        id: id,
        dogId: id,
        dogName: dog,
        staffMemberId: staffId,
        staffMemberName: 'Staff $staffId',
        ownerName: 'Owner',
        date: DateTime(2030, 6, 1),
        status: AssignmentStatus.assigned,
        effectiveOwnerBrings: ownerBoth,
        effectiveOwnerCollects: ownerBoth,
        sortOrder: sortOrder,
      );
    }

    test('numbers each staff run by sortOrder then name', () {
      final numbers = pickupRunNumbers([
        make(1, 7, 'Zeus', 1),
        make(2, 7, 'Alfie', 0),
        make(3, 7, 'Bella', 0),
        make(4, 9, 'Rex', 0),
      ]);
      // Staff 7: Alfie & Bella tie on sortOrder 0 → name order, Zeus last.
      expect(numbers[2], 1);
      expect(numbers[3], 2);
      expect(numbers[1], 3);
      // Staff 9 numbers independently.
      expect(numbers[4], 1);
    });

    test('owner-handles-both dogs are off the run', () {
      final numbers = pickupRunNumbers([
        make(1, 7, 'Alfie', 0),
        make(2, 7, 'Bella', 1, ownerBoth: true),
        make(3, 7, 'Zeus', 2),
      ]);
      expect(numbers[1], 1);
      expect(numbers[2], isNull);
      expect(numbers[3], 2);
    });
  });
}
