import 'dart:async';

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
  String? _error;
  Timer? _timeout;
  int _opening = 0;
  bool get surfaceVisible => _ready && !_covered && widget.visible;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final opening = ++_opening;
    bool current() => mounted && opening == _opening;
    final uri = widget.uri;
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
        ),
      );
      _browser = browser;
      await browser.setVisibility(false);
      if (!current()) return;
      await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!current()) return;
      await browser.setNavigationDelegate(
        WinNavigationDelegate(
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
            _timeout?.cancel();
            setState(() => _ready = true);
            _visibility();
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
