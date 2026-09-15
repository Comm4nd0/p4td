import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/owner_handover_status.dart';

void main() {
  test('parses both legs from the API payload', () {
    final status = OwnerHandoverStatus.fromJson({
      'date': '2026-09-16',
      'drop_off': {
        'leg': 'DROP_OFF',
        'count': 1,
        'dogs': [
          {'dog_id': 7, 'dog_name': 'Buddy', 'dog_profile_image': null, 'time': '08:30'},
        ],
        'staff_member_id': null,
        'staff_member_name': null,
      },
      'collection': {
        'leg': 'COLLECTION',
        'count': 0,
        'dogs': [],
        'staff_member_id': 5,
        'staff_member_name': 'Sam',
      },
    });
    expect(status.dropOff.count, 1);
    expect(status.dropOff.dogs.single.dogName, 'Buddy');
    expect(status.dropOff.dogs.single.time, '08:30');
    expect(status.dropOff.needsStaff, isTrue);
    expect(status.collection.needsStaff, isFalse);
    expect(status.collection.staffMemberName, 'Sam');
    expect(status.isEmpty, isFalse);
    expect(status[OwnerHandoverLeg.collection].staffMemberId, 5);
  });

  test('missing legs parse as empty', () {
    final status = OwnerHandoverStatus.fromJson({});
    expect(status.isEmpty, isTrue);
    expect(status.dropOff.needsStaff, isFalse);
  });
}
