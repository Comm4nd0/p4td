import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/models/day_changes.dart';

Map<String, dynamic> change({
  int dog = 1,
  String kind = 'CANCELLED',
  int? usual = 7,
  int? staff,
  bool mine = true,
  bool late = false,
  bool acknowledged = false,
  String? by = 'Sam',
}) =>
    {
      'dog_id': dog,
      'dog_name': 'Bella',
      'kind': kind,
      'detail': 'Day cancelled',
      'usual_staff_id': usual,
      'usual_staff_name': usual == null ? null : 'Jo',
      'staff_id': staff,
      'staff_name': staff == null ? null : 'Sam',
      'changed_by_name': by,
      'changed_at': '2026-10-21T18:30:00+01:00',
      'mine': mine,
      'late': late,
      'acknowledged': acknowledged,
    };

void main() {
  test('parses the changes payload', () {
    final day = DayChanges.fromJson({
      'date': '2026-10-22',
      'weekday': 'Wednesday',
      'changes': [change()],
    });
    expect(day.weekday, 'Wednesday');
    expect(day.changes.single.isCancelled, isTrue);
    expect(day.changes.single.description, 'Day cancelled · by Sam');
    expect(day.changes.single.changedAt, isNotNull);
  });

  test('only late, unconfirmed changes on my run need confirming', () {
    final day = DayChanges.fromJson({
      'date': '2026-10-22',
      'weekday': 'Wednesday',
      'changes': [
        change(dog: 1, late: true),
        change(dog: 2, late: true, acknowledged: true),
        change(dog: 3, late: true, mine: false),
        change(dog: 4),
      ],
    });
    expect(day.needsConfirming.map((c) => c.dogId), [1]);
  });

  test('a cancelled or boarding regular dog is missing from its usual list', () {
    final cancelled = DayChange.fromJson(change(usual: 7));
    final boarding = DayChange.fromJson(change(kind: 'BOARDING', usual: 7, staff: 99));
    final extra = DayChange.fromJson(change(kind: 'EXTRA', usual: 7, staff: 7));
    expect(cancelled.isMissingFrom(7), isTrue);
    expect(cancelled.isMissingFrom(8), isFalse);
    expect(boarding.isMissingFrom(7), isTrue);
    expect(extra.isMissingFrom(7), isFalse);
  });

  test('roster rows read day_changes and keep them through copyWith', () {
    final a = DailyDogAssignment.fromJson({
      'id': 1,
      'dog': 2,
      'dog_name': 'Rex',
      'staff_member': 3,
      'date': '2026-10-24',
      'status': 'ASSIGNED',
      'day_changes': ['EXTRA', 'TRANSPORT'],
    });
    expect(a.isExtraDay, isTrue);
    expect(a.hasTransportChange, isTrue);
    expect(a.copyWith(sortOrder: 4).dayChanges, ['EXTRA', 'TRANSPORT']);

    final cached = DailyDogAssignment.fromJson({
      'id': 1,
      'dog': 2,
      'dog_name': 'Rex',
      'staff_member': 3,
      'date': '2026-10-24',
      'status': 'ASSIGNED',
    });
    expect(cached.dayChanges, isEmpty);
  });
}
