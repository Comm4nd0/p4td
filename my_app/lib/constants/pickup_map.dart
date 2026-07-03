import 'package:flutter/material.dart';

import '../models/daily_dog_assignment.dart';

/// Constants + helpers for the staff pickup map.

/// Base / depot location, used when a dog has no geocodable address.
/// Chiltern View, Henley Road, Medmenham, SL7 2HE (what3words ///foal.actual.bypasses).
const double kBaseLatitude = 51.555465;
const double kBaseLongitude = -0.845921;
const String kBaseLabel = 'Base — Chiltern View, Medmenham';

/// Palette of visually distinct colours for staff pins, chosen to stay legible
/// over an OpenStreetMap background.
const List<Color> kStaffPalette = [
  Color(0xFFE53935), // red
  Color(0xFF1E88E5), // blue
  Color(0xFF43A047), // green
  Color(0xFFF4511E), // deep orange
  Color(0xFF8E24AA), // purple
  Color(0xFF00897B), // teal
  Color(0xFFC0CA33), // lime
  Color(0xFF6D4C41), // brown
  Color(0xFFD81B60), // pink
  Color(0xFF3949AB), // indigo
  Color(0xFF7CB342), // light green
  Color(0xFF00ACC1), // cyan
  Color(0xFFFB8C00), // orange
  Color(0xFF5E35B1), // deep purple
];

/// Colour shown for dogs with no staff assigned.
const Color kUnassignedColor = Color(0xFF9E9E9E);

/// Deterministic, stable colour for a staff member.
///
/// A colour the member chose themselves ([custom], keyed by staff id) always
/// wins. Otherwise [orderedStaffIds] — the sorted list of staff ids — maps each
/// member to a fixed palette slot (colours don't shuffle day to day). Falls back
/// to the member's id when it isn't in the list, so a colour is always returned.
Color staffColor(int staffMemberId, List<int> orderedStaffIds,
    {Map<int, Color> custom = const {}}) {
  final chosen = custom[staffMemberId];
  if (chosen != null) return chosen;
  final index = orderedStaffIds.indexOf(staffMemberId);
  final slot = index >= 0 ? index : staffMemberId.abs();
  return kStaffPalette[slot % kStaffPalette.length];
}

/// Parse a '#RRGGBB' hex string (as stored in UserProfile.staff_color) into a
/// Color. Returns null for blank or malformed values so callers fall back to
/// the automatic palette.
Color? parseStaffColorHex(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final match = RegExp(r'^#([0-9A-Fa-f]{6})$').firstMatch(hex);
  if (match == null) return null;
  return Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
}

/// 1-based pickup-run position per assignment id, per staff member.
///
/// Matches the map's route order exactly: dogs with no staff transport leg
/// today (owner handles both legs, or mid-boarding dogs already with staff)
/// get no number, the rest sort by (sortOrder, then dog name) within each
/// staff member's run. Shown as the numbered badges on assignment cards,
/// day-board rows and map pins so every screen agrees on the order.
Map<int, int> pickupRunNumbers(Iterable<DailyDogAssignment> assignments) {
  final byStaff = <int, List<DailyDogAssignment>>{};
  for (final a in assignments) {
    if (a.noStaffTransport) continue;
    byStaff.putIfAbsent(a.staffMemberId, () => []).add(a);
  }
  final numbers = <int, int>{};
  byStaff.forEach((_, list) {
    list.sort((a, b) {
      final cmp = a.sortOrder.compareTo(b.sortOrder);
      if (cmp != 0) return cmp;
      return a.dogName.toLowerCase().compareTo(b.dogName.toLowerCase());
    });
    for (var i = 0; i < list.length; i++) {
      numbers[list[i].id] = i + 1;
    }
  });
  return numbers;
}

/// Resolves staff colours from the /staff_members/ payload: each member's own
/// chosen colour when set, otherwise their stable palette slot. Build one per
/// screen from `getStaffMembers()` and use [of] everywhere a staff colour is
/// shown, so the dashboard, lists, day board and map all agree.
class StaffColorResolver {
  final List<int> orderedIds;
  final Map<int, Color> custom;

  StaffColorResolver(List<Map<String, dynamic>> staffMembers)
      : orderedIds = staffMembers.map((s) => s['id'] as int).toList()..sort(),
        custom = {
          for (final s in staffMembers)
            if (parseStaffColorHex(s['staff_color'] as String?) != null)
              s['id'] as int: parseStaffColorHex(s['staff_color'] as String?)!,
        };

  const StaffColorResolver.empty()
      : orderedIds = const [],
        custom = const {};

  Color of(int staffMemberId) =>
      staffColor(staffMemberId, orderedIds, custom: custom);
}
