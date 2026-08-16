import 'package:flutter/material.dart';

abstract final class OLColors {
  static const cobalt = Color(0xFF246BFD);
  static const cobaltSoft = Color(0xFFEEF5FF);
  static const navy = Color(0xFF0B1B3A);
  static const muted = Color(0xFF718096);
  static const iconMuted = Color(0xFFA8B2C1);
  static const border = Color(0xFFD9E1EC);
  static const surface = Color(0xFFF7F9FC);
  static const background = Color(0xFFFFFFFF);
  static const warning = Color(0xFFE08A17);
  static const deadline = Color(0xFFD98522);
}

abstract final class OLSpacing {
  static const xs = 6.0;
  static const sm = 10.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 36.0;
}

ThemeData openLoopTheme() => ThemeData(
  brightness: Brightness.light,
  scaffoldBackgroundColor: OLColors.background,
  colorScheme: ColorScheme.fromSeed(
    seedColor: OLColors.cobalt,
    brightness: Brightness.light,
    primary: OLColors.cobalt,
    surface: OLColors.background,
  ),
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      color: OLColors.navy,
      fontSize: 34,
      height: 1.24,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.5,
    ),
    titleLarge: TextStyle(color: OLColors.navy, fontWeight: FontWeight.w800),
    bodyLarge: TextStyle(color: OLColors.navy, height: 1.5),
    bodyMedium: TextStyle(color: OLColors.muted, height: 1.5),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: OLColors.background,
    foregroundColor: OLColors.navy,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    centerTitle: false,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: OLColors.surface,
    hintStyle: const TextStyle(color: OLColors.muted),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: OLColors.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: OLColors.cobalt, width: 1.5),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: OLColors.cobalt,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: const TextStyle(fontWeight: FontWeight.w800),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: OLColors.navy,
      side: const BorderSide(color: OLColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: OLColors.cobalt,
    foregroundColor: Colors.white,
    elevation: 2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(18)),
    ),
  ),
  chipTheme: const ChipThemeData(
    backgroundColor: OLColors.background,
    selectedColor: OLColors.cobaltSoft,
    side: BorderSide(color: OLColors.border),
    labelStyle: TextStyle(color: OLColors.navy),
    secondaryLabelStyle: TextStyle(
      color: OLColors.cobalt,
      fontWeight: FontWeight.w700,
    ),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
    ),
  ),
  dividerColor: OLColors.border,
  useMaterial3: true,
);

class OLCard extends StatelessWidget {
  const OLCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: OLColors.background,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: OLColors.border),
    ),
    child: child,
  );
}

class OLInfoBanner extends StatelessWidget {
  const OLInfoBanner({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: OLColors.cobaltSoft,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: OLColors.cobalt.withValues(alpha: .22)),
    ),
    child: Text(
      text,
      style: const TextStyle(color: OLColors.navy, height: 1.45),
    ),
  );
}
