/// A section of the staff dashboard that a person can move.
///
/// [id] is what is saved on their profile (`dashboard_layout`), so it must
/// never change. Declaration order is the standard layout. Sections with
/// [followsDate] show the selected day and swipe with the date; the rest stay
/// put. The saved-data banner isn't here on purpose: it says how far to trust
/// everything else, so it always stays on top.
enum DashboardSection {
  unassigned('unassigned', 'Unassigned dogs', followsDate: true),
  conflicts('conflicts', 'Grouping conflicts', followsDate: true),
  dayChanges('day_changes', 'Changes to the routine', followsDate: true),
  overview('overview', 'Dog counts', followsDate: true),
  handovers('handovers', 'Dropped off / collected by owner', followsDate: true),
  photoTagging('photo_tagging', 'Photo tagging', followsDate: true),
  staff('staff', 'Staff and their dogs', followsDate: true),
  actionItems('action_items', 'Action Items'),
  boarding('boarding', 'Boarding'),
  recentActivity('recent_activity', 'Recent Activity');

  final String id;
  final String label;
  final bool followsDate;

  const DashboardSection(this.id, this.label, {this.followsDate = false});
}

/// The order to draw the dashboard in, from a person's saved [ids].
///
/// Tolerates a layout saved by another app version: unknown ids and
/// duplicates are dropped, and a section the saved layout doesn't mention
/// (one added since) goes straight after the section it follows in the
/// standard order, so nothing can ever go missing from the dashboard.
List<DashboardSection> resolveDashboardLayout(List<String> ids) {
  final byId = {for (final s in DashboardSection.values) s.id: s};
  final order = <DashboardSection>[];
  for (final id in ids) {
    final section = byId[id];
    if (section != null && !order.contains(section)) order.add(section);
  }
  DashboardSection? previous;
  for (final section in DashboardSection.values) {
    if (!order.contains(section)) {
      order.insert(previous == null ? 0 : order.indexOf(previous) + 1, section);
    }
    previous = section;
  }
  return order;
}
