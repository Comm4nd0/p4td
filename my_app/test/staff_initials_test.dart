import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/utils/staff_initials.dart';

void main() {
  test('a unique first letter stands alone', () {
    expect(staffPinInitials({1: 'Verity', 2: 'lily'}), {1: 'V', 2: 'L'});
  });

  test('people sharing a letter get two', () {
    expect(staffPinInitials({1: 'Ali', 2: 'Ailsa 🐾', 3: 'Jessica'}),
        {1: 'Al', 2: 'Ai', 3: 'J'});
  });

  test('emoji are ignored', () {
    expect(staffPinInitials({1: '🐶 Marco'}), {1: 'M'});
  });

  test('a name with no letters gets no entry', () {
    expect(staffPinInitials({1: '🐶', 2: ''}), isEmpty);
  });
}
