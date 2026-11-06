import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/dashboard_layout.dart';
import 'package:paws4thoughtdogs/models/user_profile.dart';

void main() {
  test('nothing saved is the standard order', () {
    expect(resolveDashboardLayout(const []), DashboardSection.values);
  });

  test('a full saved order is kept exactly', () {
    final reversed = DashboardSection.values.reversed.toList();
    expect(resolveDashboardLayout([for (final s in reversed) s.id]), reversed);
  });

  test('unknown ids and duplicates are dropped', () {
    final order = resolveDashboardLayout([
      DashboardSection.boarding.id,
      'from_a_newer_app',
      DashboardSection.boarding.id,
      for (final s in DashboardSection.values)
        if (s != DashboardSection.boarding) s.id,
    ]);
    expect(order.first, DashboardSection.boarding);
    expect(order.toSet(), DashboardSection.values.toSet());
    expect(order.length, DashboardSection.values.length);
  });

  test('a section the saved layout lacks lands after its standard neighbour', () {
    final saved = [
      for (final s in DashboardSection.values.reversed)
        if (s != DashboardSection.boarding) s.id,
    ];
    final order = resolveDashboardLayout(saved);
    expect(order.indexOf(DashboardSection.boarding),
        order.indexOf(DashboardSection.actionItems) + 1);
    expect(order.length, DashboardSection.values.length);
  });

  test('a missing first section goes to the top', () {
    final saved = [
      for (final s in DashboardSection.values)
        if (s != DashboardSection.unassigned) s.id,
    ];
    expect(resolveDashboardLayout(saved), DashboardSection.values);
  });

  group('profile', () {
    Map<String, dynamic> json(Object? layout) => {
          'username': 'sam',
          'email': 'sam@example.com',
          'dashboard_layout': layout,
        };

    test('reads the saved layout, and copes with an older server', () {
      expect(UserProfile.fromJson(json(['boarding'])).dashboardLayout, ['boarding']);
      expect(UserProfile.fromJson(json(null)).dashboardLayout, isEmpty);
    });

    test('saving the profile screen does not send the layout', () {
      final profile = UserProfile.fromJson(json(['boarding']));
      expect(profile.toJson().containsKey('dashboard_layout'), isFalse);
    });
  });
}
