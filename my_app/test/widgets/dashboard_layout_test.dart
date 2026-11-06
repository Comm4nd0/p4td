import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/daily_dog_assignment.dart';
import 'package:paws4thoughtdogs/models/dashboard_layout.dart';
import 'package:paws4thoughtdogs/models/day_changes.dart';
import 'package:paws4thoughtdogs/screens/unified_dashboard_screen.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

/// A weekday roster plus a change, so day sections render deterministically.
class _FakeDataService extends MockDataService {
  final List<List<String>> saved = [];
  bool failSave = false;

  static DailyDogAssignment _assignment(DateTime date) => DailyDogAssignment(
        id: 1,
        dogId: 7,
        dogName: 'Rex',
        staffMemberId: 5,
        staffMemberName: 'Sam',
        ownerName: 'Alex',
        date: date,
        status: AssignmentStatus.assigned,
      );

  @override
  CachedEntry<List<DailyDogAssignment>>? cachedTodayAssignments(DateTime date) =>
      (data: [_assignment(date)], cachedAt: null);

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) async =>
      [_assignment(date ?? DateTime.now())];

  @override
  Future<DayChanges> getDayChanges({DateTime? date}) async => DayChanges(
        date: date ?? DateTime.now(),
        weekday: 'Friday',
        changes: const [
          DayChange(dogId: 8, dogName: 'Bella', kind: DayChange.cancelled, detail: 'Day cancelled'),
        ],
      );

  @override
  Future<void> saveDashboardLayout(List<String> sectionIds) async {
    if (failSave) throw Exception('offline');
    saved.add(sectionIds);
  }
}

final _friday = DateTime(2026, 7, 31);
final _saturday = DateTime(2026, 8, 1);
const _changes = 'Changes vs a normal Friday';

List<String> _ids(List<DashboardSection> first) => [
      for (final s in first) s.id,
      for (final s in DashboardSection.values)
        if (!first.contains(s)) s.id,
    ];

Future<_FakeDataService> _pump(
  WidgetTester tester, {
  List<String> layout = const [],
  DateTime? date,
  ValueChanged<List<String>>? onChanged,
}) async {
  final fake = _FakeDataService();
  if (getIt.isRegistered<DataService>()) getIt.unregister<DataService>();
  getIt.registerSingleton<DataService>(fake);
  addTearDown(() => getIt.unregister<DataService>());
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: UnifiedDashboardScreen(
        isStaff: true,
        initialDate: date ?? _friday,
        dashboardLayout: layout,
        onDashboardLayoutChanged: onChanged,
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return fake;
}

Future<void> _openLayout(WidgetTester tester) async {
  await tester.tap(find.text('Quick Actions'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('Layout'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

double _y(WidgetTester tester, String text) => tester.getTopLeft(find.text(text).first).dy;

void main() {
  testWidgets('the standard layout keeps the roster above Action Items', (tester) async {
    await _pump(tester);
    expect(_y(tester, 'Sam'), lessThan(_y(tester, 'Action Items')));
  });

  testWidgets('a saved layout moves a fixed section above the roster', (tester) async {
    await _pump(tester, layout: _ids([DashboardSection.actionItems]));
    expect(_y(tester, 'Action Items'), lessThan(_y(tester, 'Sam')));
    expect(find.text('Sam'), findsOneWidget);
  });

  testWidgets('day sections split around a fixed one all render',
      (tester) async {
    await _pump(tester,
        layout: _ids([
          DashboardSection.dayChanges,
          DashboardSection.actionItems,
          DashboardSection.staff,
        ]));
    expect(_y(tester, _changes), lessThan(_y(tester, 'Action Items')));
    expect(_y(tester, 'Action Items'), lessThan(_y(tester, 'Sam')));
  });

  testWidgets('a weekend shows one notice, however many panes the day is split into',
      (tester) async {
    await _pump(tester,
        date: _saturday,
        layout: _ids([
          DashboardSection.dayChanges,
          DashboardSection.actionItems,
          DashboardSection.staff,
        ]));
    expect(find.text('Boarding only — no daycare at the weekend'), findsOneWidget);
  });

  testWidgets('a section moved to the bottom of a long page is still built', (tester) async {
    // The spotlight can only reach a card that exists, so it mustn't depend
    // on the section being near the top of a lazy list.
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, layout: [
      for (final s in DashboardSection.values)
        if (s != DashboardSection.dayChanges) s.id,
      DashboardSection.dayChanges.id,
    ]);
    expect(find.text(_changes), findsOneWidget);
    expect(_y(tester, _changes), greaterThan(_y(tester, 'Recent Activity')));
  });

  testWidgets('a wide screen keeps day and fixed sections in their columns, in order',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester,
        layout: _ids([DashboardSection.recentActivity, DashboardSection.actionItems]));
    expect(tester.getTopLeft(find.text('Action Items')).dx,
        greaterThan(tester.getTopRight(find.text('Sam')).dx));
    expect(_y(tester, 'Recent Activity'), lessThan(_y(tester, 'Action Items')));
  });

  testWidgets('Layout saves a dragged order and applies it at once', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    List<String>? told;
    final fake = await _pump(tester, onChanged: (ids) => told = ids);
    await _openLayout(tester);

    // Reset does nothing yet: this is already the standard order.
    final reset = find.widgetWithText(TextButton, 'Reset');
    expect(tester.widget<TextButton>(reset).onPressed, isNull);

    final handle = find.descendant(
      of: find.ancestor(
        of: find.text(DashboardSection.recentActivity.label).last,
        matching: find.byType(Row),
      ).first,
      matching: find.byType(ReorderableDragStartListener),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (var step = 0; step < 30; step++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(fake.saved, hasLength(1));
    expect(fake.saved.single.first, DashboardSection.recentActivity.id);
    expect(told, fake.saved.single);
    expect(_y(tester, 'Recent Activity'), lessThan(_y(tester, 'Sam')));
  });

  testWidgets('Reset returns to the standard order', (tester) async {
    final reversed = [for (final s in DashboardSection.values.reversed) s.id];
    final fake = await _pump(tester, layout: reversed);
    await _openLayout(tester);
    await tester.tap(find.text('Reset'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(fake.saved.single, [for (final s in DashboardSection.values) s.id]);
    expect(_y(tester, 'Sam'), lessThan(_y(tester, 'Action Items')));
  });

  testWidgets('Cancel, or saving no change, writes nothing', (tester) async {
    final fake = await _pump(tester);
    await _openLayout(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    await _openLayout(tester);
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(fake.saved, isEmpty);
  });

  testWidgets('a failed save keeps the new order and says so', (tester) async {
    final reversed = [for (final s in DashboardSection.values.reversed) s.id];
    final fake = await _pump(tester, layout: reversed);
    fake.failSave = true;
    await _openLayout(tester);
    await tester.tap(find.text('Reset'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Could not save your layout'), findsOneWidget);
    expect(_y(tester, 'Sam'), lessThan(_y(tester, 'Action Items')));
  });
}
