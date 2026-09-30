import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/owner_calendar.dart';

void main() {
  CalendarDogEntry entry(Map<String, dynamic> extra) =>
      CalendarDogEntry.fromJson({'id': 1, 'name': 'Fido', ...extra});

  test('a regular day is daycare and an extra day says so', () {
    expect(entry({'boarding': false}).describe(DateTime(2030, 6, 10)), 'Daycare');
    final extraDay = entry({'boarding': false, 'extra': true});
    expect(extraDay.extra, isTrue);
    expect(extraDay.describe(DateTime(2030, 6, 10)), 'Extra day');
  });

  test('boarding days name the stay by its nights', () {
    final dog = entry({
      'boarding': true,
      'boarding_stay': {'start': '2030-06-20', 'end': '2030-06-21', 'nights': 1},
    });
    expect(dog.describe(DateTime(2030, 6, 20)), 'Arrives for boarding · 1 night, Thu 20 – Fri 21 Jun');
    expect(dog.describe(DateTime(2030, 6, 21)), 'Goes home from boarding · 1 night, Thu 20 – Fri 21 Jun');
  });

  test('a stay across months names both months, and the middle days are plain boarding', () {
    final dog = entry({
      'boarding': true,
      'boarding_stay': {'start': '2030-06-29', 'end': '2030-07-02', 'nights': 3},
    });
    expect(dog.describe(DateTime(2030, 6, 30)), 'Boarding · 3 nights, Sat 29 Jun – Tue 2 Jul');
  });

  test('older servers without the new fields still parse', () {
    final dog = entry({'boarding': true});
    expect(dog.extra, isFalse);
    expect(dog.boardingStay, isNull);
    expect(dog.describe(DateTime(2030, 6, 20)), 'Boarding');
  });
}
