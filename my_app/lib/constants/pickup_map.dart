import 'package:flutter/material.dart';

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
/// [orderedStaffIds] is the sorted list of staff ids on the map, so each member
/// maps to a fixed palette slot (colours don't shuffle day to day). Falls back
/// to the member's id when it isn't in the list, so a colour is always returned.
Color staffColor(int staffMemberId, List<int> orderedStaffIds) {
  final index = orderedStaffIds.indexOf(staffMemberId);
  final slot = index >= 0 ? index : staffMemberId.abs();
  return kStaffPalette[slot % kStaffPalette.length];
}
