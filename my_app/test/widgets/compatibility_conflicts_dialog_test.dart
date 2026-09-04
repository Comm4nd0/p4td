import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/screens/dashboard/compatibility_conflicts_dialog.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';

/// Staff have their own pickup groups, but the groups mix once everyone is at
/// the daycare. So the warning must cover two incompatible dogs that are
/// merely in on the same day as well as two in the same van — and it must say
/// which of the two it is.
CompatibilityConflict _sameGroup() => CompatibilityConflict(
      scope: CompatibilityConflictScope.sameGroup,
      staffMemberId: 5,
      staffMemberName: 'Sam',
      dogAId: 1,
      dogAName: 'Rex',
      dogAStaffName: 'Sam',
      dogBId: 2,
      dogBName: 'Buddy',
      dogBStaffName: 'Sam',
      reasons: const ['Fights at pickup'],
    );

CompatibilityConflict _sameDay({String? bStaff = 'Jo'}) => CompatibilityConflict(
      scope: CompatibilityConflictScope.sameDay,
      staffMemberId: null,
      staffMemberName: '',
      dogAId: 3,
      dogAName: 'Max',
      dogAStaffName: 'Sam',
      dogBId: 4,
      dogBName: 'Luna',
      dogBStaffName: bStaff,
      reasons: const ['Snaps at Luna'],
    );

Future<void> _open(WidgetTester tester, List<CompatibilityConflict> conflicts) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => showCompatibilityConflictsDialog(context, conflicts),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('compatibilityConflictSummary', () {
    test('names only the kind that applies', () {
      expect(compatibilityConflictSummary([_sameGroup()]),
          '1 pair in the same pickup group');
      expect(compatibilityConflictSummary([_sameDay(), _sameDay()]),
          '2 pairs in the daycare on the same day');
    });

    test('names both kinds when both apply', () {
      expect(
        compatibilityConflictSummary([_sameGroup(), _sameDay(), _sameDay()]),
        '1 pair in the same pickup group, 2 pairs in the daycare on the same day',
      );
    });
  });

  group('CompatibilityConflict.fromJson', () {
    test('reads a same-day pair with a null shared driver', () {
      final c = CompatibilityConflict.fromJson({
        'scope': 'SAME_DAY',
        'staff_member_id': null,
        'staff_member_name': '',
        'dog_a_id': 3,
        'dog_a_name': 'Max',
        'dog_a_staff_id': 5,
        'dog_a_staff_name': 'Sam',
        'dog_b_id': 4,
        'dog_b_name': 'Luna',
        'dog_b_staff_id': null,
        'dog_b_staff_name': null,
        'reasons': ['Snaps'],
      });
      expect(c.scope, CompatibilityConflictScope.sameDay);
      expect(c.isSameGroup, isFalse);
      expect(c.staffMemberId, isNull);
      expect(c.dogAStaffName, 'Sam');
      expect(c.dogBStaffName, isNull);
    });

    test('a response without a scope is a same-group pair', () {
      final c = CompatibilityConflict.fromJson({
        'staff_member_id': 5,
        'staff_member_name': 'Sam',
        'dog_a_id': 1,
        'dog_a_name': 'Rex',
        'dog_b_id': 2,
        'dog_b_name': 'Buddy',
        'reasons': [],
      });
      expect(c.isSameGroup, isTrue);
      expect(c.staffMemberId, 5);
    });
  });

  group('showCompatibilityConflictsDialog', () {
    testWidgets('same-group pairs are listed under their shared driver',
        (tester) async {
      await _open(tester, [_sameGroup()]);
      expect(find.text('Same pickup & drop-off group'), findsOneWidget);
      expect(find.text('Sam'), findsOneWidget);
      expect(find.text('Rex + Buddy'), findsOneWidget);
      expect(find.text('Fights at pickup'), findsOneWidget);
      expect(find.text('In the daycare on the same day'), findsNothing);
    });

    testWidgets('same-day pairs say which driver has which dog',
        (tester) async {
      await _open(tester, [_sameDay(bStaff: null)]);
      expect(find.text('In the daycare on the same day'), findsOneWidget);
      expect(find.text('Same pickup & drop-off group'), findsNothing);
      expect(find.text('Max + Luna'), findsOneWidget);
      expect(
        find.text('Max: with Sam\nLuna: no driver yet\nSnaps at Luna'),
        findsOneWidget,
      );
    });

    testWidgets('both sections appear when both kinds are present',
        (tester) async {
      await _open(tester, [_sameGroup(), _sameDay()]);
      expect(find.text('Same pickup & drop-off group'), findsOneWidget);
      expect(find.text('In the daycare on the same day'), findsOneWidget);
      expect(find.text('Max: with Sam\nLuna: with Jo\nSnaps at Luna'),
          findsOneWidget);
    });
  });
}
