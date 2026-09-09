import 'package:flutter/material.dart';

import '../domain/appearance.dart';
import '../domain/preferences.dart';
import 'workbench_theme.dart';

final class SettingsPane extends StatefulWidget {
  const SettingsPane({
    required this.preferences,
    required this.onPreview,
    required this.onApply,
    required this.onClose,
    this.workspace,
    super.key,
  });
  final Preferences preferences;
  final String? workspace;
  final ValueChanged<Preferences?> onPreview;
  final Future<void> Function(Preferences) onApply;
  final VoidCallback onClose;
  @override
  State<SettingsPane> createState() => _SettingsPaneState();
}

final class _SettingsPaneState extends State<SettingsPane> {
  late Preferences value = widget.preferences;
  String category = 'Appearance';
  String query = '';
  Brightness advancedMode = Brightness.light;
  bool saving = false;
  void change(Preferences next) {
    setState(() => value = next);
    widget.onPreview(next);
  }

  bool matches(String text) =>
      query.isEmpty || text.toLowerCase().contains(query);

  @override
  Widget build(BuildContext context) {
    final issues = contrastIssues(value.appearance);
    final appearance = value.appearance;
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        ListTile(
          title: const Text('Settings'),
          trailing: IconButton(
            tooltip: 'Cancel and close settings',
            icon: const Icon(Icons.close),
            onPressed: () {
              widget.onPreview(null);
              widget.onClose();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search settings',
            ),
            onChanged: (text) =>
                setState(() => query = text.toLowerCase().trim()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            children: [
              for (final name in [
                'Appearance',
                'Editor',
                'Privacy & persistence',
              ])
                ChoiceChip(
                  label: Text(name),
                  selected: category == name,
                  onSelected: (_) => setState(() => category = name),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (category == 'Appearance' || query.isNotEmpty) ...[
                if (matches('Appearance theme mode system light dark'))
                  DropdownButtonFormField<AppTheme>(
                    initialValue: value.theme,
                    key: ValueKey(value.theme),
                    decoration: const InputDecoration(labelText: 'Mode'),
                    items: [
                      for (final theme in AppTheme.values)
                        DropdownMenuItem(value: theme, child: Text(theme.name)),
                    ],
                    onChanged: (theme) => change(value.copyWith(theme: theme)),
                  ),
                if (matches('Appearance theme preset Tabryo Ocean Violet'))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final preset in ThemePreset.values)
                          ChoiceChip(
                            label: Text(switch (preset) {
                              ThemePreset.tabryo => 'Tabryo',
                              ThemePreset.ocean => 'Ocean',
                              ThemePreset.violet => 'Violet',
                            }),
                            selected: appearance.preset == preset,
                            onSelected: (_) => change(
                              value.copyWith(
                                appearance: Appearance(preset: preset),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                for (final entry in <String, int?>{
                  'Primary · selection and actions': appearance.primary,
                  'Secondary · navigation': appearance.secondary,
                  'Tertiary · highlights': appearance.tertiary,
                }.entries)
                  if (matches(entry.key))
                    _ColorField(
                      label: entry.key,
                      color: entry.value,
                      onChanged: (color) => change(
                        value.copyWith(
                          appearance: switch (entry.key.split(' ').first) {
                            'Primary' => appearance.copyWith(primary: color),
                            'Secondary' => appearance.copyWith(
                              secondary: color,
                            ),
                            _ => appearance.copyWith(tertiary: color),
                          },
                        ),
                      ),
                    ),
                if (matches(
                  'advanced surface text border focus added removed modified contrast',
                ))
                  ExpansionTile(
                    title: const Text('Advanced colors'),
                    children: [
                      SegmentedButton<Brightness>(
                        segments: const [
                          ButtonSegment(
                            value: Brightness.light,
                            label: Text('Light'),
                          ),
                          ButtonSegment(
                            value: Brightness.dark,
                            label: Text('Dark'),
                          ),
                        ],
                        selected: {advancedMode},
                        onSelectionChanged: (mode) =>
                            setState(() => advancedMode = mode.first),
                      ),
                      for (final token in Appearance.advancedTokens)
                        _ColorField(
                          key: ValueKey('${advancedMode.name}:$token'),
                          label: token,
                          color: (advancedMode == Brightness.light
                              ? appearance.light
                              : appearance.dark)[token],
                          onChanged: (color) {
                            final overrides = {
                              ...(advancedMode == Brightness.light
                                  ? appearance.light
                                  : appearance.dark),
                              token: color,
                            };
                            change(
                              value.copyWith(
                                appearance: advancedMode == Brightness.light
                                    ? appearance.copyWith(light: overrides)
                                    : appearance.copyWith(dark: overrides),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                if (issues.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Insufficient contrast: ${issues.join(', ')}',
                            style: TextStyle(color: colors.error),
                          ),
                          TextButton(
                            onPressed: () => change(
                              value.copyWith(
                                appearance: correctContrast(appearance),
                              ),
                            ),
                            child: const Text('Correct contrast'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (matches('preview appearance theme'))
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Appearance preview',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            'Editor text, selected actions and Git changes share these colors.',
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            children: [
                              FilledButton(
                                onPressed: () {},
                                child: const Text('Primary action'),
                              ),
                              const Chip(label: Text('Selected file')),
                              Text(
                                '+ Added',
                                style: TextStyle(
                                  color: WorkbenchColors.of(context).added,
                                ),
                              ),
                              Text(
                                '− Removed',
                                style: TextStyle(
                                  color: WorkbenchColors.of(context).removed,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (category == 'Editor' || query.isNotEmpty) ...[
                if (matches('terminal editor font family'))
                  TextFormField(
                    initialValue: value.fontFamily,
                    decoration: const InputDecoration(
                      labelText: 'Terminal font family',
                    ),
                    onChanged: (font) => change(
                      value.copyWith(
                        fontFamily: font.trim().isEmpty
                            ? 'monospace'
                            : font.trim(),
                      ),
                    ),
                  ),
                if (matches('terminal font size'))
                  ListTile(
                    title: const Text('Font size'),
                    subtitle: Slider(
                      value: value.fontSize,
                      min: 10,
                      max: 24,
                      divisions: 14,
                      label: '${value.fontSize.round()}',
                      onChanged: (size) =>
                          change(value.copyWith(fontSize: size)),
                    ),
                  ),
                if (matches('monitor workspace open documents'))
                  CheckboxListTile(
                    value: value.watchFiles,
                    title: const Text('Monitor workspace and open documents'),
                    onChanged: (enabled) =>
                        change(value.copyWith(watchFiles: enabled)),
                  ),
                if (widget.workspace != null &&
                    matches('Dart executable format save'))
                  TextFormField(
                    initialValue: value.dartFormatters[widget.workspace] ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Dart executable for format on save',
                      helperText:
                          'This workspace only. Empty disables formatting.',
                    ),
                    onChanged: (path) {
                      final paths = {...value.dartFormatters};
                      if (path.trim().isEmpty) {
                        paths.remove(widget.workspace);
                      } else {
                        paths[widget.workspace!] = path.trim();
                      }
                      change(value.copyWith(dartFormatters: paths));
                    },
                  ),
              ],
              if (category == 'Privacy & persistence' || query.isNotEmpty) ...[
                if (matches(
                  'remember appearance editor monitoring preferences drafts',
                ))
                  CheckboxListTile(
                    value: value.rememberPreferences,
                    title: const Text(
                      'Remember appearance, editor and monitoring preferences',
                    ),
                    subtitle: const Text(
                      'Includes conversation drafts, which may contain source text.',
                    ),
                    onChanged: (enabled) =>
                        change(value.copyWith(rememberPreferences: enabled)),
                  ),
                if (matches('remember workspace folders'))
                  CheckboxListTile(
                    value: value.rememberWorkspaces,
                    title: const Text('Remember workspace folders'),
                    onChanged: (enabled) =>
                        change(value.copyWith(rememberWorkspaces: enabled)),
                  ),
                if (matches('remember restore layout windows'))
                  CheckboxListTile(
                    value: value.restoreLayout,
                    title: const Text('Remember layouts and window placement'),
                    subtitle: const Text(
                      'Commands and services never restart automatically.',
                    ),
                    onChanged: (enabled) =>
                        change(value.copyWith(restoreLayout: enabled)),
                  ),
                if (matches('recover unsaved documents crash'))
                  CheckboxListTile(
                    value: value.recoverDocuments,
                    title: const Text(
                      'Recover unsaved documents after a crash',
                    ),
                    subtitle: const Text(
                      'Stores local text copies. Turning off clears this session and offered recovery copies.',
                    ),
                    onChanged: (enabled) =>
                        change(value.copyWith(recoverDocuments: enabled)),
                  ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => change(
                  value.copyWith(
                    theme: AppTheme.system,
                    appearance: const Appearance(),
                  ),
                ),
                child: const Text('Restore default appearance'),
              ),
              TextButton(
                onPressed: saving
                    ? null
                    : () {
                        widget.onPreview(null);
                        widget.onClose();
                      },
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: saving || issues.isNotEmpty
                    ? null
                    : () async {
                        setState(() => saving = true);
                        await widget.onApply(value);
                        widget.onPreview(null);
                        if (mounted) setState(() => saving = false);
                      },
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _ColorField extends StatelessWidget {
  const _ColorField({
    required this.label,
    required this.color,
    required this.onChanged,
    super.key,
  });
  final String label;
  final int? color;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextFormField(
      key: ValueKey('$label:$color'),
      initialValue: color == null
          ? ''
          : color!.toRadixString(16).substring(2).toUpperCase(),
      decoration: InputDecoration(
        labelText: label,
        prefixText: '#',
        hintText: 'Automatic',
        prefixIcon: color == null
            ? null
            : Icon(Icons.circle, color: Color(color!)),
      ),
      maxLength: 6,
      onChanged: (text) {
        final parsed = int.tryParse(text, radix: 16);
        if (text.length == 6 && parsed != null) onChanged(0xff000000 | parsed);
      },
    ),
  );
}
