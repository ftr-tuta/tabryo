// Flutter HardwareKeyboard is presentation input state; Dartitect 1.1.0
// classifies the SDK's services/ source directory as infrastructure.
// ignore_for_file: dartitect_dt3121

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../../preferences/domain/preferences.dart';
import '../../preferences/presentation/workbench_theme.dart';
import 'terminal_session.dart';

final class TerminalPaneView extends StatefulWidget {
  const TerminalPaneView({
    required this.session,
    required this.preferences,
    required this.focused,
    required this.onFocus,
    required this.onClose,
    required this.readClipboard,
    required this.writeClipboard,
    super.key,
  });
  final TerminalSession session;
  final Preferences preferences;
  final bool focused;
  final VoidCallback onFocus;
  final VoidCallback onClose;
  final Future<String?> Function() readClipboard;
  final Future<void> Function(String) writeClipboard;
  @override
  State<TerminalPaneView> createState() => _TerminalPaneViewState();
}

final class _TerminalPaneViewState extends State<TerminalPaneView> {
  final _focus = FocusNode();
  final _controller = TerminalController();
  final _scroll = ScrollController();
  final _query = TextEditingController();
  bool _searching = false;
  bool _visible = false;
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_visible) _requestFocus();
    _visible = visible;
  }

  void _requestFocus() {
    if (widget.focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _visible && widget.focused) _focus.requestFocus();
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
      final text = widget.session.terminal.buffer.getText(range);
      await widget.writeClipboard(text);
    }
  }

  Future<void> _paste() async {
    final text = await widget.readClipboard();
    if (!mounted) return;
    if (text == null) return;
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
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        keyboard.isControlPressed &&
        keyboard.isShiftPressed) {
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
    // xterm's hardware fallback inserts dead-key labels before Windows commits
    // their composed text. Let the platform text client handle printable input
    // (including AltGr), while xterm retains control/navigation key encoding.
    final altGr =
        keyboard.isControlPressed &&
        keyboard.isAltPressed &&
        keyboard.physicalKeysPressed.contains(PhysicalKeyboardKey.altRight);
    final plainText =
        !keyboard.isMetaPressed &&
        ((!keyboard.isControlPressed && !keyboard.isAltPressed) || altGr);
    final printable =
        ((event.character?.isNotEmpty ?? false) &&
            event.character!.runes.every(
              (rune) => rune >= 0x20 && rune != 0x7f,
            )) ||
        event.logicalKey.keyLabel.runes.length == 1;
    if (defaultTargetPlatform == TargetPlatform.windows &&
        event is! KeyUpEvent &&
        plainText &&
        printable) {
      return KeyEventResult.skipRemainingHandlers;
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
            theme: terminalTheme(context),
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
