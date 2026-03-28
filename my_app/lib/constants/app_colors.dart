import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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

  // ── Dark-mode surface / background ─────────────────────────────────
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color darkSurfaceVariant = Color(0xFF2C2C2C);

  // ── Material ColorScheme helpers ─────────────────────────────────
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

  static ColorScheme get darkScheme => ColorScheme.fromSeed(
        seedColor: primary,
        primary: primaryLight,
        onPrimary: Colors.white,
        secondary: primary,
        onSecondary: cream,
        surface: darkSurface,
        onSurface: const Color(0xFFE0E0E0),
        error: const Color(0xFFCF6679),
        onError: Colors.black,
        brightness: Brightness.dark,
      );

  /// Build a complete [ThemeData] for light or dark mode.
  static ThemeData lightTheme() {
    final textTheme = GoogleFonts.nunitoTextTheme(ThemeData.light().textTheme);
    return ThemeData(
      colorScheme: lightScheme,
      useMaterial3: true,
      textTheme: textTheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: primary,
        foregroundColor: cream,
        titleTextStyle: GoogleFonts.nunito(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: cream,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primary,
        unselectedItemColor: grey600,
      ),
    );
  }

  static ThemeData darkTheme() {
    final textTheme = GoogleFonts.nunitoTextTheme(ThemeData.dark().textTheme);
    return ThemeData(
      colorScheme: darkScheme,
      useMaterial3: true,
      textTheme: textTheme,
      scaffoldBackgroundColor: darkBackground,
      appBarTheme: AppBarTheme(
        backgroundColor: darkSurface,
        foregroundColor: cream,
        titleTextStyle: GoogleFonts.nunito(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: cream,
        ),
      ),
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 2,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: darkSurface,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: darkSurface,
        selectedItemColor: primaryLight,
        unselectedItemColor: grey500,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: darkSurface,
      ),
      dividerTheme: DividerThemeData(
        color: darkSurfaceVariant,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurfaceVariant,
      ),
    );
  }
}
