import 'dart:ui';

import 'package:ente_components/ente_components.dart' as components;
import 'package:flutter/material.dart';
import 'package:photos/theme/colors.dart';
import 'package:photos/theme/effects.dart';
import 'package:photos/theme/ente_theme.dart';
import 'package:photos/theme/text_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The accent color the user picked for the app (Settings -> Appearance -> Accent color).
class AccentColors {
  const AccentColors._();

  /// SharedPreferences key; part of the settings that are backed up to Filen.
  static const prefsKey = 'filen.accent_color';

  /// Filen's blue is the default.
  static const Color defaultColor = Color(0xFF0A84FF);

  static const List<({String name, Color color})> options = [
    (name: 'Blue', color: Color(0xFF0A84FF)),
    (name: 'Green', color: Color(0xFF1DB954)),
    (name: 'Teal', color: Color(0xFF14B8A6)),
    (name: 'Purple', color: Color(0xFF8B5CF6)),
    (name: 'Pink', color: Color(0xFFEC4899)),
    (name: 'Orange', color: Color(0xFFF97316)),
    (name: 'Red', color: Color(0xFFE5484D)),
    (name: 'Gray', color: Color(0xFF6B7280)),
  ];

  static Color current = defaultColor;

  /// Reads the saved choice and applies it. Call before the first frame.
  static Future<void> load(SharedPreferences prefs) async {
    final saved = prefs.getInt(prefsKey);
    apply(saved == null ? defaultColor : Color(saved));
  }

  /// Applies [color] to both color systems of the app; the caller rebuilds the theme.
  static void apply(Color color) {
    current = color;
    components.componentAccentSeed = color;
    lightTheme = EnteTheme(
      lightTextTheme,
      lightScheme.withAccent(color),
      shadowFloat: shadowFloatLight,
      shadowMenu: shadowMenuLight,
      shadowButton: shadowButtonLight,
    );
    darkTheme = EnteTheme(
      darkTextTheme,
      darkScheme.withAccent(color),
      shadowFloat: shadowFloatDark,
      shadowMenu: shadowMenuDark,
      shadowButton: shadowButtonDark,
    );
  }

  static Future<void> save(SharedPreferences prefs, Color color) async {
    // ignore: deprecated_member_use
    await prefs.setInt(prefsKey, color.toARGB32());
    apply(color);
  }
}
