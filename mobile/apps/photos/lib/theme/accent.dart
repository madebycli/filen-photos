import 'dart:ui';

import 'package:ente_components/ente_components.dart' as components;
import 'package:filen_sdk/filen_sdk.dart';
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

  /// Whether the accent follows the wallpaper colors of Android 12+ ("Material You").
  static const systemKey = 'filen.accent_system';

  static const List<({String name, Color color})> options = [
    (name: 'Blue', color: Color(0xFF0A84FF)),
    (name: 'Sky', color: Color(0xFF38BDF8)),
    (name: 'Cyan', color: Color(0xFF06B6D4)),
    (name: 'Teal', color: Color(0xFF14B8A6)),
    (name: 'Mint', color: Color(0xFF10B981)),
    (name: 'Green', color: Color(0xFF1DB954)),
    (name: 'Amber', color: Color(0xFFD97706)),
    (name: 'Orange', color: Color(0xFFF97316)),
    (name: 'Red', color: Color(0xFFE5484D)),
    (name: 'Rose', color: Color(0xFFF43F5E)),
    (name: 'Pink', color: Color(0xFFEC4899)),
    (name: 'Magenta', color: Color(0xFFD946EF)),
    (name: 'Purple', color: Color(0xFF8B5CF6)),
    (name: 'Indigo', color: Color(0xFF6366F1)),
    (name: 'Brown', color: Color(0xFF8D6E63)),
    (name: 'Slate', color: Color(0xFF475569)),
    (name: 'Gray', color: Color(0xFF6B7280)),
  ];

  static Color current = defaultColor;
  static bool useSystem = false;

  /// The wallpaper accent of this phone, or null where Android does not offer one (before 12).
  static Future<Color?> systemColor() async {
    try {
      final value = await FilenSdk.instance.systemAccent();
      return value == null ? null : Color(value);
    } catch (_) {
      return null;
    }
  }

  /// Reads the saved choice and applies it. Call before the first frame.
  static Future<void> load(SharedPreferences prefs) async {
    useSystem = prefs.getBool(systemKey) ?? false;
    final saved = prefs.getInt(prefsKey);
    var color = saved == null ? defaultColor : Color(saved);
    if (useSystem) color = await systemColor() ?? color;
    apply(color);
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
    await prefs.setBool(systemKey, false);
    useSystem = false;
    apply(color);
  }

  /// Follow the wallpaper colors; returns false when this phone has none.
  static Future<bool> saveSystem(SharedPreferences prefs) async {
    final color = await systemColor();
    if (color == null) return false;
    await prefs.setBool(systemKey, true);
    useSystem = true;
    apply(color);
    return true;
  }
}
