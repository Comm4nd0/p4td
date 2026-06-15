import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/constants/pickup_map.dart';

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
  });
}
