enum AppTheme { system, dark, light }

final class Preferences {
  const Preferences({
    this.theme = AppTheme.system,
    this.fontFamily = 'monospace',
    this.fontSize = 14,
    this.rememberPreferences = false,
    this.rememberWorkspaces = false,
    this.restoreLayout = false,
    this.watchFiles = false,
    this.roots = const [],
    this.layout = const [],
  });
  final AppTheme theme;
  final String fontFamily;
  final double fontSize;
  final bool rememberPreferences;
  final bool rememberWorkspaces;
  final bool restoreLayout;
  final bool watchFiles;
  final List<String> roots;
  final List<Map<String, Object?>> layout;

  Preferences copyWith({
    AppTheme? theme,
    String? fontFamily,
    double? fontSize,
    bool? rememberPreferences,
    bool? rememberWorkspaces,
    bool? restoreLayout,
    bool? watchFiles,
    List<String>? roots,
    List<Map<String, Object?>>? layout,
  }) => Preferences(
    theme: theme ?? this.theme,
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: fontSize ?? this.fontSize,
    rememberPreferences: rememberPreferences ?? this.rememberPreferences,
    rememberWorkspaces: rememberWorkspaces ?? this.rememberWorkspaces,
    restoreLayout: restoreLayout ?? this.restoreLayout,
    watchFiles: watchFiles ?? this.watchFiles,
    roots: roots ?? this.roots,
    layout: layout ?? this.layout,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'rememberPreferences': rememberPreferences,
    'rememberWorkspaces': rememberWorkspaces,
    'restoreLayout': restoreLayout,
    if (rememberPreferences) ...{
      'theme': theme.name,
      'fontFamily': fontFamily,
      'fontSize': fontSize,
      'watchFiles': watchFiles,
    },
    if (rememberWorkspaces) 'roots': roots,
    if (restoreLayout) 'layout': layout,
  };

  factory Preferences.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported preferences version.');
    }
    final remember = json['rememberPreferences'] == true;
    final size = (json['fontSize'] as num?)?.toDouble() ?? 14;
    return Preferences(
      rememberPreferences: remember,
      rememberWorkspaces: json['rememberWorkspaces'] == true,
      restoreLayout: json['restoreLayout'] == true,
      theme: remember
          ? AppTheme.values.firstWhere(
              (t) => t.name == json['theme'],
              orElse: () => AppTheme.system,
            )
          : AppTheme.system,
      fontFamily: remember
          ? ((json['fontFamily'] as String?) ?? 'monospace')
          : 'monospace',
      fontSize: remember ? size.clamp(10, 24) : 14,
      watchFiles: remember && json['watchFiles'] == true,
      roots: json['rememberWorkspaces'] == true
          ? List<String>.from(json['roots'] as List? ?? []).take(30).toList()
          : [],
      layout: json['restoreLayout'] == true
          ? (json['layout'] as List? ?? [])
                .take(30)
                .map((v) => Map<String, Object?>.from(v as Map))
                .toList()
          : [],
    );
  }
}

final class PreferencesLoad {
  const PreferencesLoad(this.preferences, {this.warning});
  final Preferences preferences;
  final String? warning;
}

abstract interface class PreferencesStore {
  Future<PreferencesLoad> load();
  Future<void> save(Preferences preferences);
}
