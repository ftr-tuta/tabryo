enum ThemePreset { tabryo, ocean, violet }

/// Portable opaque sRGB tokens. Platform color objects stay in presentation.
final class Appearance {
  const Appearance({
    this.preset = ThemePreset.tabryo,
    this.primary,
    this.secondary,
    this.tertiary,
    this.light = const {},
    this.dark = const {},
  });
  final ThemePreset preset;
  final int? primary;
  final int? secondary;
  final int? tertiary;
  final Map<String, int> light;
  final Map<String, int> dark;

  static const advancedTokens = [
    'surface',
    'text',
    'border',
    'focus',
    'added',
    'removed',
    'modified',
  ];

  Appearance copyWith({
    ThemePreset? preset,
    int? primary,
    int? secondary,
    int? tertiary,
    Map<String, int>? light,
    Map<String, int>? dark,
  }) => Appearance(
    preset: preset ?? this.preset,
    primary: primary ?? this.primary,
    secondary: secondary ?? this.secondary,
    tertiary: tertiary ?? this.tertiary,
    light: light ?? this.light,
    dark: dark ?? this.dark,
  );

  Map<String, Object?> toJson() => {
    'preset': preset.name,
    if (primary != null) 'primary': primary,
    if (secondary != null) 'secondary': secondary,
    if (tertiary != null) 'tertiary': tertiary,
    'light': light,
    'dark': dark,
  };

  factory Appearance.fromJson(Object? value) {
    if (value is! Map) return const Appearance();
    int? color(Object? v) =>
        v is int && v >= 0xff000000 && v <= 0xffffffff ? v : null;
    Map<String, int> tokens(Object? v) => v is Map
        ? {
            for (final key in advancedTokens)
              if (color(v[key]) case final int c) key: c,
          }
        : const {};
    return Appearance(
      preset:
          ThemePreset.values
              .where((p) => p.name == value['preset'])
              .firstOrNull ??
          ThemePreset.tabryo,
      primary: color(value['primary']),
      secondary: color(value['secondary']),
      tertiary: color(value['tertiary']),
      light: tokens(value['light']),
      dark: tokens(value['dark']),
    );
  }
}
