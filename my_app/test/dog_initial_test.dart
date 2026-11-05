import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/utils/dog_initial.dart';

void main() {
  test('the first letter of the name, in capitals', () {
    expect(dogPinInitial('Skyler'), 'S');
    expect(dogPinInitial('molly'), 'M');
  });

  test('anything before the first letter is skipped', () {
    expect(dogPinInitial('🐶 Rex'), 'R');
    expect(dogPinInitial('"Bo" Jones'), 'B');
  });

  test('a name with no letters has no initial', () {
    expect(dogPinInitial('🐶'), isNull);
    expect(dogPinInitial(''), isNull);
  });
}
