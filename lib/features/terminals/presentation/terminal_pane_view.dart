import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../../preferences/domain/preferences.dart';
import 'terminal_session.dart';

final class TerminalPaneView extends StatefulWidget {
  const TerminalPaneView({
    required this.session,
    required this.preferences,
    required this.focused,
    required this.onFocus,
    required this.onClose,
    super.key,
  });
  final TerminalSession session;
  final Preferences preferences;
  final bool focused;
  final VoidCallback onFocus;
  final VoidCallback onClose;
  @override
  State<TerminalPaneView> createState() => _TerminalPaneViewState();
}

final class _TerminalPaneViewState extends State<TerminalPaneView> {
  final _focus = FocusNode();
  final _controller = TerminalController();
  final _scroll = ScrollController();
  final _query = TextEditingController();
  bool _searching = false;
  int _matchIndex = 0;
  List<TerminalSearchMatch> _matches = [];
  @override
  void initState() {
    super.initState();
    _focus.addListener(_focused);
    _requestFocus();
  }

  void _focused() {
    if (_focus.hasFocus) widget.onFocus();
  }

  void _requestFocus() {
    if (widget.focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(TerminalPaneView old) {
    super.didUpdateWidget(old);
    if (widget.focused && !old.focused) _requestFocus();
  }

  @override
  void dispose() {
    _focus.removeListener(_focused);
    _focus.dispose();
    _controller.dispose();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final range = _controller.selection;
    if (range != null) {
      await Clipboard.setData(
        ClipboardData(text: widget.session.terminal.buffer.getText(range)),
      );
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null) return;
    final text = data!.text!;
    if (text.contains('\n') || text.contains('\r')) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Paste multiple lines?'),
          content: const Text(
            'A shell may execute these lines immediately. Review the clipboard before continuing.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Paste'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    widget.session.terminal.paste(text);
    _focus.requestFocus();
  }

  void _search([int direction = 0]) {
    _matches = widget.session.terminal.search(_query.text, maxResults: 200);
    if (_matches.isNotEmpty) {
      _matchIndex = (_matchIndex + direction) % _matches.length;
      final range = _matches[_matchIndex].range;
      final buffer = widget.session.terminal.buffer;
      _controller.setSelection(
        buffer.createAnchor(range.begin.x, range.begin.y),
        buffer.createAnchor(range.end.x, range.end.y),
      );
      if (_scroll.hasClients) {
        _scroll.jumpTo(
          (range.begin.y * widget.preferences.fontSize * 1.2).clamp(
            0,
            _scroll.position.maxScrollExtent,
          ),
        );
      }
    }
    setState(() {});
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed && keyboard.isShiftPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyC) {
        _copy();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        _paste();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        setState(() => _searching = !_searching);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(
        color: widget.focused
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).dividerColor,
        width: widget.focused ? 2 : 1,
      ),
    ),
    child: Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Icon(
                widget.session.status == SessionStatus.running
                    ? Icons.circle
                    : Icons.check_circle_outline,
                size: 10,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${widget.session.title} · ${widget.session.status.name}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              IconButton(
                tooltip: 'Search scrollback (Ctrl+Shift+F)',
                icon: const Icon(Icons.search, size: 17),
                onPressed: () => setState(() => _searching = !_searching),
              ),
              IconButton(
                tooltip: 'Copy selection (Ctrl+Shift+C)',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: _copy,
              ),
              IconButton(
                tooltip: 'Paste (Ctrl+Shift+V)',
                icon: const Icon(Icons.content_paste, size: 16),
                onPressed: _paste,
              ),
              IconButton(
                tooltip: 'Close terminal',
                icon: const Icon(Icons.close, size: 17),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        if (_searching)
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    onChanged: (_) {
                      _matchIndex = 0;
                      _search();
                    },
                    decoration: const InputDecoration(
                      hintText: 'Search scrollback',
                      isDense: true,
                      contentPadding: EdgeInsets.all(8),
                    ),
                  ),
                ),
                Text(
                  '${_matches.isEmpty ? 0 : _matchIndex + 1}/${_matches.length}',
                ),
                IconButton(
                  onPressed: () => _search(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  onPressed: () => _search(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ],
            ),
          ),
        if (widget.session.message != null)
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              widget.session.message!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: TerminalView(
            widget.session.terminal,
            controller: _controller,
            focusNode: _focus,
            scrollController: _scroll,
            textStyle: TerminalStyle(
              fontFamily: widget.preferences.fontFamily,
              fontSize: widget.preferences.fontSize,
            ),
            theme: TerminalThemes.defaultTheme,
            padding: const EdgeInsets.all(8),
            onKeyEvent: _key,
            shortcuts: const <ShortcutActivator, Intent>{},
            onSecondaryTapUp: (_, _) => _paste(),
            onHyperlinkTap: (_) {},
          ),
        ),
      ],
    ),
  );
}
