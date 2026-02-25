import 'package:flutter/material.dart';

/// Paws 4 Thought Dogs brand colors, derived from the website palette.
class AppColors {
  AppColors._();

  // ── Primary brand colours ──────────────────────────────────────────
  /// Deep teal – main brand colour (website primary).
  static const Color primary = Color(0xFF165144);

  /// Very dark teal – used for emphasis / secondary surfaces.
  static const Color primaryDark = Color(0xFF01332E);

  /// Lighter teal for highlights, chips, tags, selected states.
  static const Color primaryLight = Color(0xFF2A7A68);

  // ── Surface / background ───────────────────────────────────────────
  /// Off-white page background matching the website.
  static const Color background = Color(0xFFEEEEEE);

  /// Cream / warm white used for text on dark backgrounds.
  static const Color cream = Color(0xFFF5EDE8);

  /// Pure white for cards and elevated surfaces.
  static const Color surface = Color(0xFFFFFFFF);

  // ── Header / Footer ────────────────────────────────────────────────
  /// Muted teal used in the website header.
  static const Color header = Color(0xFF225D3F);

  /// Dark olive-brown used in the website footer.
  static const Color footer = Color(0xFF272C1B);

  // ── Buttons / actions ──────────────────────────────────────────────
  /// Dark charcoal button background from the website.
  static const Color buttonDark = Color(0xFF32373C);

  // ── Semantic / status colours ──────────────────────────────────────
  static const Color success = Color(0xFF2E7D32); // green
  static const Color error = Color(0xFFC62828); // red
  static const Color warning = Color(0xFFEF6C00); // orange
  static const Color info = Color(0xFF165144); // brand teal (replaces blue)

  // ── Neutral greys ──────────────────────────────────────────────────
  static const Color grey100 = Color(0xFFF5F5F5);
  static const Color grey200 = Color(0xFFEEEEEE);
  static const Color grey300 = Color(0xFFE0E0E0);
  static const Color grey400 = Color(0xFFBDBDBD);
  static const Color grey500 = Color(0xFF9E9E9E);
  static const Color grey600 = Color(0xFF757575);
  static const Color grey700 = Color(0xFF616161);

  // ── Material ColorScheme helper ────────────────────────────────────
  static ColorScheme get lightScheme => ColorScheme.fromSeed(
        seedColor: primary,
        primary: primary,
        onPrimary: cream,
        secondary: primaryLight,
        onSecondary: Colors.white,
        surface: surface,
        onSurface: const Color(0xFF1C1C1C),
        error: error,
        onError: Colors.white,
        brightness: Brightness.light,
      );
}
