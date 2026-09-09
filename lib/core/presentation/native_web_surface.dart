// The pinned native WebView host adds attachToView to the package channel.
// This adapter owns presentation only; the caller owns the browser and profile.
// MethodChannel belongs here to adapt the pinned native presentation backend.
// ignore_for_file: dartitect_dt3121
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_win_floating/webview_win_floating.dart';
import 'package:webview_win_floating/webview_win_floating_method_channel.dart';
import 'package:webview_win_floating/webview_win_floating_platform_interface.dart';

final class NativeWebSurface extends StatefulWidget {
  const NativeWebSurface({
    required this.controller,
    required this.visible,
    required this.onError,
    super.key,
  });
  final WinWebViewController controller;
  final bool visible;
  final VoidCallback onError;
  static final _pending = <Future<void>>{};
  static final _failures = <_NativeWebSurfaceState, Object>{};
  static Future<void> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
    if (_failures.isNotEmpty) {
      throw StateError(
        'Native surface transfer failed: ${_failures.values.first}',
      );
    }
  }

  @override
  State<NativeWebSurface> createState() => _NativeWebSurfaceState();
}

final class _NativeWebSurfaceState extends State<NativeWebSurface> {
  static const _channel = MethodChannel('webview_win_floating');
  int? _attachedView;
  Future<void> _serial = Future.value();
  int _revision = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(NativeWebSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _schedule() {
    final view = View.of(context);
    final revision = ++_revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _revision) return;
      final operation = _serial
          .then((_) async {
            if (!mounted || revision != _revision) return;
            final controller = widget.controller;
            // Await native creation before consulting the pinned controller registry.
            await controller.setVisibility(
              _attachedView == view.viewId && widget.visible,
            );
            final platform = WebviewWinFloatingPlatform.instance;
            if (platform is! MethodChannelWebviewWinFloating) {
              throw StateError('Unsupported native WebView backend.');
            }
            final id = platform.webviewMap.entries
                .where((entry) => identical(entry.value.target, controller))
                .first
                .key;
            if (_attachedView != view.viewId) {
              await _channel.invokeMethod<void>('attachToView', {
                'webviewId': id,
                'viewId': view.viewId,
              });
              _attachedView = view.viewId;
            }
            if (!mounted || revision != _revision) return;
            final box = context.findRenderObject() as RenderBox?;
            if (box == null || !box.hasSize) return;
            final offset = box.localToGlobal(Offset.zero);
            final scale = view.devicePixelRatio;
            await _channel.invokeMethod<bool>('updateBounds', {
              'webviewId': id,
              'left': (offset.dx * scale).round(),
              'top': (offset.dy * scale).round(),
              'right': ((offset.dx + box.size.width) * scale).round(),
              'bottom': ((offset.dy + box.size.height) * scale).round(),
            });
            await controller.setVisibility(mounted && widget.visible);
            NativeWebSurface._failures.remove(this);
          })
          .catchError((Object error) {
            if (mounted) {
              NativeWebSurface._failures[this] = error;
              widget.onError();
            }
          });
      _serial = operation;
      NativeWebSurface._pending.add(operation);
      unawaited(
        operation.whenComplete(
          () => NativeWebSurface._pending.remove(operation),
        ),
      );
    });
  }

  @override
  void deactivate() {
    ++_revision;
    unawaited(widget.controller.setVisibility(false));
    super.deactivate();
  }

  @override
  void dispose() {
    NativeWebSurface._failures.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, _) {
      _schedule();
      return WinWebViewWidget(controller: widget.controller);
    },
  );
}
