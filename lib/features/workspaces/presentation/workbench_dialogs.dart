import 'package:flutter/material.dart';

import '../../preferences/domain/preferences.dart';
import 'workbench_view_model.dart';

final class WorkbenchDialogs {
  WorkbenchDialogs(this.context, this.model);
  final BuildContext context;
  final WorkbenchViewModel model;

  Future<String?> input(
    String title,
    String label, {
    String value = '',
    String? explanation,
    int lines = 1,
  }) async {
    var text = value;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (explanation != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(explanation),
                ),
              TextFormField(
                initialValue: value,
                autofocus: true,
                minLines: lines,
                maxLines: lines == 1 ? 1 : 8,
                decoration: InputDecoration(
                  labelText: label,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) => text = value,
                onFieldSubmitted: lines == 1
                    ? (value) => Navigator.pop(context, value)
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<bool> confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> openWorkspace() async {
    final path = await input(
      'Open workspace',
      'Absolute folder path',
      explanation: 'Choose a local project folder. Opening it does not start a terminal.',
    );
    if (path != null && path.trim().isNotEmpty) await model.openWorkspace(path);
  }

  Future<void> commit() => model.guarded(() async {
    final repo = await model.selectedRepository();
    final identity = await model.gitReader.identity(repo);
    if (!context.mounted) return;
    final message = await input(
      'Commit changes',
      'Commit message',
      lines: 4,
      explanation:
          'Author: ${identity.name} <${identity.email}>\nConfiguration sources:\n${identity.origins}\nGit hooks, signing, and prompts remain enabled.',
    );
    if (message != null) {
      await model.runGitCommand(
        (repo) => model.gitMutator.commit(repo, message),
        'Git commit',
      );
    }
  });

  Future<void> remote(String command) => model.guarded(() async {
    final names = await model.gitReader.remotes(
      await model.selectedRepository(),
    );
    if (names.isEmpty) {
      throw StateError(
        'This repository has no remotes. Configure one with Git first.',
      );
    }
    if (!context.mounted) return;
    final selected = await input(
      '${command == 'push' ? 'Push to' : 'Fetch from'} remote',
      'Remote name',
      value: names.first,
      explanation:
          'Available: ${names.join(', ')}\nThe command runs in an interactive terminal using your Git authentication configuration.',
    );
    if (selected != null) {
      await model.runGitCommand(
        (repo) => model.gitMutator.remoteCommand(repo, command, selected),
        'Git $command',
      );
    }
  });

  Future<void> createWorktree() async {
    var branch = '';
    var base = 'HEAD';
    var destination = '';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create worktree'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Review the new branch, starting revision, and destination. Existing files will not be replaced.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                autofocus: true,
                decoration: const InputDecoration(labelText: 'New branch'),
                onChanged: (v) => branch = v,
              ),
              TextFormField(
                initialValue: 'HEAD',
                decoration: const InputDecoration(labelText: 'Base revision'),
                onChanged: (v) => base = v,
              ),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Absolute destination (must not exist)',
                ),
                onChanged: (v) => destination = v,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create worktree'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await model.runGitCommand(
        (repo) =>
            model.gitMutator.createWorktree(repo, branch, base, destination),
        'Create worktree',
      );
    }
  }

  Future<void> preferences() async {
    var value = model.preferences;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Preferences'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<AppTheme>(
                    initialValue: value.theme,
                    decoration: const InputDecoration(labelText: 'Appearance'),
                    items: AppTheme.values
                        .map(
                          (theme) => DropdownMenuItem(
                            value: theme,
                            child: Text(theme.name),
                          ),
                        )
                        .toList(),
                    onChanged: (theme) =>
                        update(() => value = value.copyWith(theme: theme)),
                  ),
                  TextFormField(
                    initialValue: value.fontFamily,
                    decoration: const InputDecoration(
                      labelText: 'Terminal font family',
                    ),
                    onChanged: (font) => value = value.copyWith(
                      fontFamily: font.trim().isEmpty
                          ? 'monospace'
                          : font.trim(),
                    ),
                  ),
                  Row(
                    children: [
                      const Text('Font size'),
                      Expanded(
                        child: Slider(
                          value: value.fontSize,
                          min: 10,
                          max: 24,
                          divisions: 14,
                          label: '${value.fontSize.round()}',
                          onChanged: (size) => update(
                            () => value = value.copyWith(fontSize: size),
                          ),
                        ),
                      ),
                    ],
                  ),
                  CheckboxListTile(
                    value: value.rememberPreferences,
                    onChanged: (enabled) => update(
                      () =>
                          value = value.copyWith(rememberPreferences: enabled),
                    ),
                    title: const Text(
                      'Remember appearance and monitoring preferences',
                    ),
                  ),
                  CheckboxListTile(
                    value: value.rememberWorkspaces,
                    onChanged: (enabled) => update(
                      () => value = value.copyWith(rememberWorkspaces: enabled),
                    ),
                    title: const Text('Remember workspace folders'),
                  ),
                  CheckboxListTile(
                    value: value.restoreLayout,
                    onChanged: (enabled) => update(
                      () => value = value.copyWith(restoreLayout: enabled),
                    ),
                    title: const Text('Remember terminal layout'),
                    subtitle: const Text(
                      'Restore placeholders only. Commands never restart automatically.',
                    ),
                  ),
                  CheckboxListTile(
                    value: value.watchFiles,
                    onChanged: (enabled) => update(
                      () => value = value.copyWith(watchFiles: enabled),
                    ),
                    title: const Text('Monitor the selected workspace folder'),
                    subtitle: const Text(
                      'Root folder changes trigger refresh. Disable to stop monitoring immediately.',
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Tabryo has no account, backend, or telemetry. Git, shells, and Codex use their own policies.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) await model.updatePreferences(value);
  }
}
