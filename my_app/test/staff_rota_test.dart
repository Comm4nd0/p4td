import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/utils/staff_rota.dart';

void main() {
  // 2030-06-03 is a Monday (weekday 1).
  final monday = DateTime(2030, 6, 3);

  final coverage = {
    '1': {
      'day_name': 'Monday',
      'available': [
        {'id': 7, 'name': 'Sarah'},
        {'id': 9, 'name': 'James'},
      ],
      'unavailable': [
        {'id': 11, 'name': 'Priya'},
      ],
    },
  };

  group('workingStaffIds', () {
    test('working = on the weekday rota and not on day off', () {
      // James (9) is on the rota but has an approved day off.
      final working = workingStaffIds(
        date: monday,
        coverage: coverage,
        notOnDayOff: {7, 11}, // everyone except James
      );
      expect(working, {7}); // Sarah only: Priya is off-rota, James is on leave
    });

    test('falls back to day-off data when coverage is missing', () {
      expect(
        workingStaffIds(date: monday, coverage: {}, notOnDayOff: {7, 9}),
        {7, 9},
      );
    });

    test('falls back to the rota when day-off data is missing', () {
      expect(
        workingStaffIds(date: monday, coverage: coverage, notOnDayOff: {}),
        {7, 9},
      );
    });
  });
}
