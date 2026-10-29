import "package:adaptive_theme/adaptive_theme.dart";
import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/theme/accent.dart";
import "package:shared_preferences/shared_preferences.dart";

/// Settings -> Appearance -> Accent color: one tap applies the color to the whole app.
class AccentColorScreen extends StatefulWidget {
  const AccentColorScreen({super.key});

  @override
  State<AccentColorScreen> createState() => _AccentColorScreenState();
}

class _AccentColorScreenState extends State<AccentColorScreen> {
  Color _selected = AccentColors.current;
  bool _system = AccentColors.useSystem;
  Color? _systemColor;

  @override
  void initState() {
    super.initState();
    AccentColors.systemColor().then((color) {
      if (mounted) setState(() => _systemColor = color);
    });
  }

  Future<void> _pickSystem() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await AccentColors.saveSystem(prefs)) return;
    if (!mounted) return;
    setState(() {
      _system = true;
      _selected = AccentColors.current;
    });
    AdaptiveTheme.of(
      context,
    ).setTheme(light: lightThemeData, dark: darkThemeData);
  }

  Future<void> _pick(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await AccentColors.save(prefs, color);
    if (!mounted) return;
    setState(() {
      _selected = color;
      _system = false;
    });
    // Rebuild both themes so every screen picks the new color up.
    AdaptiveTheme.of(
      context,
    ).setTheme(light: lightThemeData, dark: darkThemeData);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return SettingsPageScaffold(
      title: "Accent color",
      children: [
        if (_systemColor != null) ...[
          MenuComponent(
            title: context.strings.accentSystemColors,
            subtitle: context.strings.accentSystemColorsHint,
            leading: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _systemColor,
                shape: BoxShape.circle,
              ),
            ),
            trailing: _system ? const Icon(Icons.check_rounded) : null,
            onTap: _pickSystem,
          ),
          const SizedBox(height: 24),
        ],
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final option in AccentColors.options)
              _Swatch(
                name: option.name,
                color: option.color,
                selected:
                    !_system && option.color.toARGB32() == _selected.toARGB32(),
                outline: colors.textBase,
                onTap: () => _pick(option.color),
              ),
          ],
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.outline,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final Color outline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? outline : Colors.transparent,
                  width: 3,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(name, style: TextStyles.mini),
          ],
        ),
      ),
    );
  }
}
