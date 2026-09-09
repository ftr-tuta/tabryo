import '../../projects/domain/project.dart';

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
    this.recoverDocuments = false,
    this.dartFormatters = const {},
    this.projectToolchains = const {},
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
  final bool recoverDocuments;
  final Map<String, String> dartFormatters;
  final Map<String, ToolchainSelection> projectToolchains;
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
    bool? recoverDocuments,
    Map<String, String>? dartFormatters,
    Map<String, ToolchainSelection>? projectToolchains,
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
    recoverDocuments: recoverDocuments ?? this.recoverDocuments,
    dartFormatters: dartFormatters ?? this.dartFormatters,
    projectToolchains: projectToolchains ?? this.projectToolchains,
    roots: roots ?? this.roots,
    layout: layout ?? this.layout,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'rememberPreferences': rememberPreferences,
    'rememberWorkspaces': rememberWorkspaces,
    'restoreLayout': restoreLayout,
    'recoverDocuments': recoverDocuments,
    if (rememberPreferences) ...{
      'theme': theme.name,
      'fontFamily': fontFamily,
      'fontSize': fontSize,
      'watchFiles': watchFiles,
      'dartFormatters': dartFormatters,
      'projectToolchains': {
        for (final entry in projectToolchains.entries)
          entry.key: entry.value.toJson(),
      },
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
      recoverDocuments: json['recoverDocuments'] == true,
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
      dartFormatters: remember
          ? Map<String, String>.from(json['dartFormatters'] as Map? ?? {})
          : const {},
      projectToolchains: remember
          ? {
              for (final entry
                  in (json['projectToolchains'] as Map? ?? {}).entries.take(
                    128,
                  ))
                entry.key as String: ToolchainSelection.fromJson(
                  entry.value as Map,
                ),
            }
          : const {},
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
