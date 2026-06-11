// Flutter 3.44+ exports CupertinoPageTransitionsBuilder only from cupertino.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Paws 4 Thought Dogs brand colors, derived from the website palette,
/// applied through an iOS-style (Cupertino-feel) theme on all platforms.
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
  /// Off-white page background matching the website (legacy – screens now
  /// sit on [iosGroupedBg]).
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

  // ── Dark-mode surface / background (legacy – kept for screens that
  // reference them directly; theme now uses the iOS dark palette) ────
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color darkSurfaceVariant = Color(0xFF2C2C2C);

  // ── iOS system palette ─────────────────────────────────────────────
  /// systemGroupedBackground – the light grey behind grouped content.
  static const Color iosGroupedBg = Color(0xFFF2F2F7);
  static const Color iosDarkBg = Color(0xFF000000);

  /// secondarySystemGroupedBackground – card surfaces.
  static const Color iosCard = Color(0xFFFFFFFF);
  static const Color iosDarkCard = Color(0xFF1C1C1E);

  /// tertiary fill – text field / search field backgrounds.
  static const Color iosFill = Color(0xFFE9E9EB);
  static const Color iosDarkFill = Color(0xFF2C2C2E);

  /// Hairline separators.
  static const Color iosSeparator = Color(0xFFC6C6C8);
  static const Color iosDarkSeparator = Color(0xFF38383A);

  /// Secondary label (subtitles, captions, unselected tabs).
  static const Color iosSecondaryLabel = Color(0xFF8A8A8E);
  static const Color iosDarkSecondaryLabel = Color(0xFF98989E);

  /// Primary label colours.
  static const Color iosLabel = Color(0xFF1C1C1E);
  static const Color iosDarkLabel = Color(0xFFE5E5EA);

  // ── Material ColorScheme helpers ─────────────────────────────────
  // Built by hand (not fromSeed) so surfaces stay pure white / iOS dark
  // grey instead of picking up a teal tonal tint.
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: primary,
    onPrimary: Colors.white,
    secondary: primaryLight,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFD7E8E1),
    onSecondaryContainer: primaryDark,
    surface: iosCard,
    onSurface: iosLabel,
    onSurfaceVariant: iosSecondaryLabel,
    surfaceContainerHighest: iosFill,
    outline: iosSeparator,
    outlineVariant: Color(0xFFE5E5EA),
    error: error,
    onError: Colors.white,
  );

  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: primaryLight,
    onPrimary: Colors.white,
    secondary: primaryLight,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFF1F3A33),
    onSecondaryContainer: Color(0xFFA8CFC2),
    surface: iosDarkCard,
    onSurface: iosDarkLabel,
    onSurfaceVariant: iosDarkSecondaryLabel,
    surfaceContainerHighest: iosDarkFill,
    outline: iosDarkSeparator,
    outlineVariant: Color(0xFF2C2C2E),
    error: Color(0xFFFF6961),
    onError: Colors.black,
  );

  /// Inter text theme following the iOS (SF Pro) type scale, mapped onto
  /// the Material slots screens already use via Theme.of(context).
  static TextTheme _iosTextTheme(Brightness brightness) {
    final base = GoogleFonts.interTextTheme(
      brightness == Brightness.dark
          ? ThemeData.dark().textTheme
          : ThemeData.light().textTheme,
    );
    return base.copyWith(
      // Large Title / Title 1 / Title 2 / Title 3
      headlineLarge: base.headlineLarge!.copyWith(
          fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.2),
      headlineMedium: base.headlineMedium!.copyWith(
          fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.2),
      headlineSmall: base.headlineSmall!.copyWith(
          fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.3),
      titleLarge: base.titleLarge!.copyWith(
          fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.45),
      // Headline / emphasized Subhead
      titleMedium: base.titleMedium!.copyWith(
          fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.4),
      titleSmall: base.titleSmall!.copyWith(
          fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.2),
      // Body / Subhead / Footnote
      bodyLarge: base.bodyLarge!.copyWith(
          fontSize: 17, letterSpacing: -0.4, height: 1.3),
      bodyMedium: base.bodyMedium!.copyWith(
          fontSize: 15, letterSpacing: -0.2, height: 1.3),
      bodySmall: base.bodySmall!.copyWith(fontSize: 13, letterSpacing: -0.1),
      // Button / Caption 1 / Caption 2
      labelLarge: base.labelLarge!.copyWith(
          fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.4),
      labelMedium:
          base.labelMedium!.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall:
          base.labelSmall!.copyWith(fontSize: 11, fontWeight: FontWeight.w500),
    );
  }

  static TextStyle _buttonTextStyle() => GoogleFonts.inter(
      fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.4);

  /// Build a complete [ThemeData] for light or dark mode.
  static ThemeData lightTheme() => _theme(Brightness.light);

  static ThemeData darkTheme() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = dark ? darkScheme : lightScheme;
    final textTheme = _iosTextTheme(brightness);
    final tint = dark ? primaryLight : primary;
    final label = dark ? iosDarkLabel : iosLabel;
    final secondaryLabel = dark ? iosDarkSecondaryLabel : iosSecondaryLabel;
    final card = dark ? iosDarkCard : iosCard;
    final fill = dark ? iosDarkFill : iosFill;
    final separator = dark ? iosDarkSeparator : iosSeparator;

    return ThemeData(
      useMaterial3: true,
      // Cupertino behaviour everywhere: bouncing scroll physics, chevron
      // back buttons, iOS text selection and `.adaptive` widgets.
      platform: TargetPlatform.iOS,
      colorScheme: scheme,
      primaryColor: tint, // legacy Theme.of(context).primaryColor call sites
      textTheme: textTheme,
      scaffoldBackgroundColor: dark ? iosDarkBg : iosGroupedBg,
      splashFactory: NoSplash.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: card,
        foregroundColor: label,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        shadowColor: const Color(0x66000000),
        centerTitle: true,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: label,
        ),
        iconTheme: IconThemeData(color: tint),
        actionsIconTheme: IconThemeData(color: tint),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: tint,
        unselectedLabelColor: secondaryLabel,
        indicatorColor: tint,
        dividerColor: separator.withValues(alpha: 0.4),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(iconColor: tint),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: _buttonTextStyle(),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: tint,
          foregroundColor: Colors.white,
          disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
          disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: _buttonTextStyle(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: tint,
          disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
          textStyle: GoogleFonts.inter(
              fontSize: 17, fontWeight: FontWeight.w400, letterSpacing: -0.4),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: tint,
          disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
          side: BorderSide(color: tint, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: _buttonTextStyle(),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: tint, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        hintStyle: TextStyle(color: secondaryLabel),
      ),
      dividerTheme: DividerThemeData(thickness: 0.5, color: separator),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: card,
        selectedItemColor: tint,
        unselectedItemColor: secondaryLabel,
        selectedLabelStyle:
            GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500),
        unselectedLabelStyle:
            GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: label,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: card,
        modalBackgroundColor: card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        clipBehavior: Clip.antiAlias,
        showDragHandle: true,
        dragHandleColor: separator,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: tint,
        foregroundColor: Colors.white,
        elevation: 0,
        highlightElevation: 0,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: tint),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: dark ? iosDarkBg : iosGroupedBg,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.secondaryContainer,
          selectedForegroundColor: scheme.onSecondaryContainer,
          side: BorderSide(color: separator, width: 0.5),
        ),
      ),
    );
  }
}
