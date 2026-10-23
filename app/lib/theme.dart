import 'package:flutter/material.dart';

/// Colours used across the app. Every lamp gets its own bright gradient.
class AppTheme {
  static const Color seed = Color(0xFF6C4DF5);

  static ThemeData light() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF3F4FA),
      );

  static ThemeData dark() => ThemeData(
        useMaterial3: true,
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      );

  static const LinearGradient header = LinearGradient(
    colors: [Color(0xFF6C4DF5), Color(0xFFB43FD8), Color(0xFFE0457B)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient allOn = LinearGradient(
    colors: [Color(0xFF34D399), Color(0xFF16A34A)],
  );

  static const LinearGradient allOff = LinearGradient(
    colors: [Color(0xFFFB7185), Color(0xFFDC2626)],
  );

  static const List<List<Color>> lampColors = [
    [Color(0xFFFFB300), Color(0xFFFF6F00)], // amber
    [Color(0xFFFF8A3D), Color(0xFFF4511E)], // orange
    [Color(0xFFFF5C8A), Color(0xFFD81B60)], // pink
    [Color(0xFFB05CFF), Color(0xFF7B1FA2)], // purple
    [Color(0xFF6C7BFF), Color(0xFF3949AB)], // indigo
    [Color(0xFF42A5F5), Color(0xFF1565C0)], // blue
    [Color(0xFF26C6DA), Color(0xFF00838F)], // cyan
    [Color(0xFF26A69A), Color(0xFF00695C)], // teal
    [Color(0xFF66BB6A), Color(0xFF2E7D32)], // green
    [Color(0xFFC0CA33), Color(0xFF827717)], // lime
    [Color(0xFFFFCA28), Color(0xFFF57F17)], // yellow
    [Color(0xFFEF5350), Color(0xFFC62828)], // red
    [Color(0xFF9575CD), Color(0xFF512DA8)], // violet
    [Color(0xFF4FC3F7), Color(0xFF0277BD)], // sky
    [Color(0xFFF06292), Color(0xFFAD1457)], // rose
  ];

  static List<Color> lampGradient(int id) =>
      lampColors[(id - 1) % lampColors.length];
}
