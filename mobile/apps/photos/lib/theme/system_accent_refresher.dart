import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:photos/ente_theme_data.dart';
import 'package:photos/services/app_navigation_service.dart';
import 'package:photos/theme/accent.dart';

/// With "system colors" on, a new wallpaper changes the accent while the app is in the background:
/// when the app comes back, the color is read again and the themes are rebuilt.
class SystemAccentRefresher with WidgetsBindingObserver {
  SystemAccentRefresher._();

  static final instance = SystemAccentRefresher._();
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state != AppLifecycleState.resumed || !AccentColors.useSystem) return;
    final color = await AccentColors.systemColor();
    if (color == null || color.toARGB32() == AccentColors.current.toARGB32()) {
      return;
    }
    AccentColors.apply(color);
    final context = AppNavigationService.instance.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      AdaptiveTheme.of(
        context,
      ).setTheme(light: lightThemeData, dark: darkThemeData);
    }
  }
}
