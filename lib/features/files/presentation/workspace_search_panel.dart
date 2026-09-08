import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../domain/workspace_files.dart';

final class WorkspaceSearchPanel extends StatefulWidget {
  const WorkspaceSearchPanel({
    required this.root,
    required this.search,
    super.key,
  });
  final String root;
  final Future<WorkspaceSearchResults> Function(
    WorkspaceSearchQuery,
    Cancellation,
  )
  search;
  @override
  State<WorkspaceSearchPanel> createState() => _WorkspaceSearchPanelState();
}

final class _WorkspaceSearchPanelState extends State<WorkspaceSearchPanel> {
  final query = TextEditingController();
  final path = TextEditingController();
  final exclusions = TextEditingController();
  bool caseSensitive = false, busy = false;
  Cancellation? cancellation;
  WorkspaceSearchResults? results;
  String? error;

  @override
  void dispose() {
    cancellation?.cancel();
    query.dispose();
    path.dispose();
    exclusions.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    cancellation?.cancel();
    final token = cancellation = Cancellation();
    setState(() {
      busy = true;
      error = null;
      results = null;
    });
    try {
      final found = await widget.search(
        WorkspaceSearchQuery(
          query.text,
          caseSensitive: caseSensitive,
          pathContains: path.text,
          excludedDirectories: exclusions.text
              .split(',')
              .map((v) => v.trim())
              .where((v) => v.isNotEmpty)
              .toList(),
        ),
        token,
      );
      token.check();
      if (mounted && identical(token, cancellation)) {
        setState(() => results = found);
      }
    } on Cancelled {
      if (mounted && identical(token, cancellation)) {
        setState(() => error = 'Search cancelled.');
      }
    } catch (e) {
      if (mounted && identical(token, cancellation)) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted && identical(token, cancellation)) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Search workspace'),
    content: SizedBox(
      width: 850,
      height: 570,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.root, maxLines: 1, overflow: TextOverflow.ellipsis),
          const Text(
            'Literal text in saved UTF-8 files. Unsaved buffers are not searched. Dependencies and build directories are excluded; Git ignore rules are not applied.',
          ),
          TextField(
            controller: query,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Search text'),
            onSubmitted: (_) => _search(),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: path,
                  decoration: const InputDecoration(
                    labelText: 'File path contains',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: exclusions,
                  decoration: const InputDecoration(
                    labelText: 'Exclude directory names (comma separated)',
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Checkbox(
                value: caseSensitive,
                onChanged: (v) => setState(() => caseSensitive = v!),
              ),
              const Text('Match case'),
              const Spacer(),
              if (busy)
                TextButton(
                  onPressed: () => cancellation?.cancel(),
                  child: const Text('Cancel search'),
                ),
              FilledButton(onPressed: _search, child: const Text('Search')),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (results case final found?) ...[
            Text(
              '${found.matches.length} matches · ${found.skipped} unreadable or unsupported files skipped${found.limited ? ' · limit reached; narrow the search' : ''}',
            ),
            Expanded(
              child: ListView.builder(
                itemCount: found.matches.length,
                itemBuilder: (context, index) {
                  final match = found.matches[index];
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${p.relative(match.path, from: widget.root)}:${match.line}:${match.column}',
                    ),
                    subtitle: Text(
                      match.preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, match),
                  );
                },
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
