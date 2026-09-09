import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

import '../../../core/web_surface_routes.dart';

/// A separate local DevTools surface. It installs no JavaScript channels.
final class DevToolsPane extends StatefulWidget {
  const DevToolsPane({
    required this.uri,
    required this.profileDirectory,
    this.visible = true,
    super.key,
  });
  final Uri uri;
  final String profileDirectory;
  final bool visible;

  @override
  State<DevToolsPane> createState() => DevToolsPaneState();
}

final class DevToolsPaneState extends State<DevToolsPane> with RouteAware {
  WinWebViewController? _browser;
  ModalRoute<dynamic>? _route;
  bool _covered = false;
  bool _ready = false;
  bool _documentReady = false;
  String? _error;
  Timer? _timeout;
  int _opening = 0;
  bool get surfaceVisible =>
      _documentReady && _error == null && !_covered && widget.visible;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final opening = ++_opening;
    bool current() => mounted && opening == _opening;
    // Use the SDK's documented JavaScript fallback in embedded WebKit, where
    // the default dart2wasm bootstrap can finish without creating the app view.
    final uri = defaultTargetPlatform == TargetPlatform.linux
        ? widget.uri.replace(
            queryParameters: {...widget.uri.queryParameters, 'compiler': 'js'},
          )
        : widget.uri;
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port == 0 ||
        uri.userInfo.isNotEmpty) {
      _fail();
      return;
    }
    _timeout = Timer(const Duration(seconds: 30), () {
      if (current()) _fail();
    });
    try {
      final browser = WinWebViewController(
        params: WindowsWebViewControllerCreationParams(
          userDataFolder: widget.profileDirectory,
          profileName: 'TabryoDevTools',
        ),
      );
      _browser = browser;
      await browser.setVisibility(false);
      if (!current()) return;
      await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!current()) return;
      await browser.setNavigationDelegate(
        WinNavigationDelegate(
          onPageStarted: (_) {
            if (!current()) return;
            unawaited(
              browser
                  .runJavaScript("""
              if (!window.tabryoDevToolsErrors) {
                window.tabryoDevToolsErrors = [];
                const record = message => {
                  if (window.tabryoDevToolsErrors.length < 8) {
                    window.tabryoDevToolsErrors.push(String(message).slice(0, 500).replace(/(?:https?|wss?):[^ ]+/g, '[endpoint]'));
                  }
                };
                window.addEventListener('error', e => record(e.message));
                window.addEventListener('unhandledrejection', e => record(e.reason));
              }
            """)
                  .catchError((Object _) {}),
            );
          },
          onNavigationRequest: (request) {
            final target = Uri.tryParse(request.url);
            return request.isMainFrame &&
                    target?.scheme == uri.scheme &&
                    target?.host == uri.host &&
                    target?.port == uri.port &&
                    target?.userInfo.isEmpty == true
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (url) {
            if (!current()) return;
            final loaded = Uri.tryParse(url);
            if (loaded?.scheme != uri.scheme ||
                loaded?.host != uri.host ||
                loaded?.port != uri.port) {
              return;
            }
            setState(() => _documentReady = true);
            _visibility();
            unawaited(_waitForApplication(browser, opening));
          },
          onWebResourceError: (error) {
            if (current() && error.isForMainFrame == true) _fail();
          },
        ),
      );
      if (!current()) return;
      setState(() {});
      await browser.loadRequest(uri);
    } catch (_) {
      if (current()) _fail();
    }
  }

  Future<void> _waitForApplication(
    WinWebViewController browser,
    int opening,
  ) async {
    try {
      while (mounted && opening == _opening && _error == null && !_ready) {
        final rendered = await browser.runJavaScriptReturningResult(
          "(document.querySelector('flt-glass-pane')?.shadowRoot?.querySelector('canvas')?.width ?? 0) > 0",
        );
        if (!mounted || opening != _opening || _error != null) return;
        if (rendered == true) {
          _timeout?.cancel();
          setState(() => _ready = true);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
      if (mounted && opening == _opening) _fail();
    }
  }

  void _fail() {
    if (!mounted) return;
    _timeout?.cancel();
    setState(() {
      _ready = false;
      _error = 'DevTools could not load. The debug session remains available.';
    });
    unawaited(_browser?.setVisibility(false));
  }

  Future<void> _retry() async {
    ++_opening;
    _timeout?.cancel();
    final previous = _browser;
    setState(() {
      _browser = null;
      _ready = false;
      _documentReady = false;
      _error = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      await previous?.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {
      /* A delayed native disposal does not prevent a retry. */
    }
    if (mounted) await _open();
  }

  void _visibility() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_browser?.setVisibility(surfaceVisible));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      editorRoutes.unsubscribe(this);
      _route = route;
      if (route != null) editorRoutes.subscribe(this, route);
    }
    _covered = _route?.isCurrent != true;
    _visibility();
  }

  @override
  void didUpdateWidget(DevToolsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.profileDirectory != widget.profileDirectory) {
      unawaited(_retry());
      return;
    }
    _visibility();
  }

  @override
  void didPushNext() {
    _covered = true;
    unawaited(_browser?.setVisibility(false));
  }

  @override
  void didPopNext() {
    unawaited(
      editorRoutes.settled.then((_) {
        if (!mounted) return;
        _covered = _route?.isCurrent != true;
        _visibility();
      }),
    );
  }

  @override
  void dispose() {
    ++_opening;
    _timeout?.cancel();
    editorRoutes.unsubscribe(this);
    unawaited(_browser?.setVisibility(false));
    unawaited(_browser?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      if (_browser != null)
        Positioned.fill(child: WinWebViewWidget(controller: _browser!)),
      if (!_ready)
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? 'Loading local DevTools…'),
              if (_error != null)
                TextButton(
                  onPressed: _retry,
                  child: const Text('Reconnect DevTools'),
                ),
            ],
          ),
        ),
    ],
  );
}
