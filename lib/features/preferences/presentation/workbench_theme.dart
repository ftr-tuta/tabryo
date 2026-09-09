import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

import '../domain/appearance.dart';

/// Preview the user's chosen token inside the appearance editor.
Color? appearanceSwatch(int? argb) => argb == null ? null : Color(argb);

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

Color readableOn(Color background) =>
    contrast(Colors.black, background) > contrast(Colors.white, background)
    ? Colors.black
    : Colors.white;

final class WorkbenchColors extends ThemeExtension<WorkbenchColors> {
  const WorkbenchColors({
    required this.added,
    required this.removed,
    required this.modified,
    required this.focus,
  });
  final Color added, removed, modified, focus;

  static WorkbenchColors of(BuildContext context) =>
      Theme.of(context).extension<WorkbenchColors>() ??
      tokens(const Appearance(), Theme.of(context).brightness);

  @override
  WorkbenchColors copyWith({
    Color? added,
    Color? removed,
    Color? modified,
    Color? focus,
  }) => WorkbenchColors(
    added: added ?? this.added,
    removed: removed ?? this.removed,
    modified: modified ?? this.modified,
    focus: focus ?? this.focus,
  );
  @override
  WorkbenchColors lerp(WorkbenchColors? other, double t) => other == null
      ? this
      : WorkbenchColors(
          added: Color.lerp(added, other.added, t)!,
          removed: Color.lerp(removed, other.removed, t)!,
          modified: Color.lerp(modified, other.modified, t)!,
          focus: Color.lerp(focus, other.focus, t)!,
        );
}

ColorScheme scheme(Appearance appearance, Brightness brightness) {
  final seed = switch (appearance.preset) {
    ThemePreset.tabryo => const Color(0xff247c68),
    ThemePreset.ocean => const Color(0xff146cc1),
    ThemePreset.violet => const Color(0xff8651c5),
  };
  final raw = ColorScheme.fromSeed(
    seedColor: appearance.primary == null ? seed : Color(appearance.primary!),
    brightness: brightness,
    secondary: appearance.secondary == null
        ? null
        : Color(appearance.secondary!),
    tertiary: appearance.tertiary == null ? null : Color(appearance.tertiary!),
  );
  final overrides = brightness == Brightness.light
      ? appearance.light
      : appearance.dark;
  final surface = overrides['surface'] == null
      ? raw.surface
      : Color(overrides['surface']!);
  final text = overrides['text'] == null
      ? readableOn(surface)
      : Color(overrides['text']!);
  Color foreground(Color color) =>
      contrast(color, surface) >= 4.5 ? color : readableOn(surface);
  final primary = foreground(raw.primary),
      secondary = foreground(raw.secondary),
      tertiary = foreground(raw.tertiary);
  return raw.copyWith(
    surface: surface,
    onSurface: text,
    onSurfaceVariant: foreground(raw.onSurfaceVariant),
    primary: primary,
    secondary: secondary,
    tertiary: tertiary,
    onPrimary: readableOn(primary),
    onSecondary: readableOn(secondary),
    onTertiary: readableOn(tertiary),
    outline: overrides['border'] == null
        ? raw.outline
        : Color(overrides['border']!),
  );
}

WorkbenchColors tokens(Appearance appearance, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final overrides = dark ? appearance.dark : appearance.light;
  Color pick(String key, int light, int darkValue) =>
      Color(overrides[key] ?? (dark ? darkValue : light));
  return WorkbenchColors(
    added: pick('added', 0xff14783b, 0xff72d69a),
    removed: pick('removed', 0xffbc303f, 0xffff8d99),
    modified: pick('modified', 0xff896400, 0xffe8c35b),
    focus: overrides['focus'] == null
        ? scheme(appearance, brightness).primary
        : Color(overrides['focus']!),
  );
}

List<String> contrastIssues(Appearance appearance) {
  final issues = <String>[];
  for (final brightness in Brightness.values) {
    final colors = scheme(appearance, brightness);
    final semantic = tokens(appearance, brightness);
    for (final pair in <String, (Color, Color, double)>{
      'text': (colors.onSurface, colors.surface, 4.5),
      'border': (colors.outline, colors.surface, 3),
      'focus': (semantic.focus, colors.surface, 3),
      'added': (semantic.added, colors.surface, 3),
      'removed': (semantic.removed, colors.surface, 3),
      'modified': (semantic.modified, colors.surface, 3),
    }.entries) {
      if (contrast(pair.value.$1, pair.value.$2) < pair.value.$3) {
        issues.add('${brightness.name}: ${pair.key}');
      }
    }
  }
  return issues;
}

Appearance correctContrast(Appearance appearance) {
  Map<String, int> corrected(Brightness brightness) {
    final colors = scheme(appearance, brightness);
    final result = {
      ...(brightness == Brightness.light ? appearance.light : appearance.dark),
    };
    for (final issue in contrastIssues(
      appearance,
    ).where((v) => v.startsWith(brightness.name))) {
      result[issue.split(': ').last] = readableOn(colors.surface).toARGB32();
    }
    return result;
  }

  return appearance.copyWith(
    light: corrected(Brightness.light),
    dark: corrected(Brightness.dark),
  );
}

ThemeData workbenchTheme(Appearance appearance, Brightness brightness) =>
    ThemeData(
      colorScheme: scheme(appearance, brightness),
      extensions: [tokens(appearance, brightness)],
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
    );

TerminalTheme terminalTheme(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  final semantic = WorkbenchColors.of(context);
  return TerminalTheme(
    cursor: semantic.focus,
    selection: colors.primary.withValues(alpha: .3),
    foreground: colors.onSurface,
    background: colors.surface,
    black: colors.onSurface,
    white: colors.onSurface,
    red: semantic.removed,
    green: semantic.added,
    yellow: semantic.modified,
    blue: colors.primary,
    magenta: colors.tertiary,
    cyan: colors.secondary,
    brightBlack: colors.onSurfaceVariant,
    brightWhite: colors.onSurface,
    brightRed: semantic.removed,
    brightGreen: semantic.added,
    brightYellow: semantic.modified,
    brightBlue: colors.primary,
    brightMagenta: colors.tertiary,
    brightCyan: colors.secondary,
    searchHitBackground: colors.tertiaryContainer,
    searchHitBackgroundCurrent: colors.primaryContainer,
    searchHitForeground: colors.onTertiaryContainer,
  );
}
