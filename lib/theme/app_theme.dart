import 'package:flutter/material.dart';

class AppTheme {
  static const _bg = Color(0xFF0F1115);
  static const _surface = Color(0xFF171A21);
  static const _accent = Color(0xFF5DE0A6);
  static const _danger = Color(0xFFFF6B6B);

  // Debit (money out) reads as an expense -> red-ish.
  // Credit (money in / manual negative) -> green-ish.
  static const positiveColor = Color(0xFFFF6B6B);
  static const negativeColor = Color(0xFF5DE0A6);

  static ThemeData get dark {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _bg,
      colorScheme: const ColorScheme.dark(
        primary: _accent,
        secondary: _accent,
        surface: _surface,
        error: _danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _bg,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: _surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: _accent,
        foregroundColor: Colors.black,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      useMaterial3: true,
    );
  }
}
