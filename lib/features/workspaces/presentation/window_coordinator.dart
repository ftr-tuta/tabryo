// Native window operations are contained in this presentation adapter.
// Flutter MethodChannel is used only for the pinned package's display query.
// ignore_for_file: dartitect_dt3121
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:multiview_desktop/multiview_desktop.dart';

import '../../../core/presentation/native_web_surface.dart';
import '../../../core/web_surface_routes.dart';

enum ToolWindow { execution, devTools, preview }

final class ToolPresentation {
  ToolPresentation(this.category, this.owner, this.title, this.builder);
  final ToolWindow category;
  final String owner;
  String title;
  WidgetBuilder builder;
  final key = GlobalKey();
  final routes = WebSurfaceRouteObserver();
  int? window;
  bool minimized = false;
  bool panelVisible = true;
}

/// One presentation per owner, at most one native window per category.
/// Services, PTYs and browser controllers stay in the existing composition.
final class WindowCoordinator extends WindowObserver
    with ChangeNotifier, WidgetsBindingObserver {
  final _presentations = <String, ToolPresentation>{};
  final _transitions = <ToolWindow, Future<void>>{};
  final _restored = <ToolWindow>{};
  int? primary;
  Future<bool> Function()? requestExit;
  Map<String, Object?> Function(ToolWindow)? readLayout;
  void Function(ToolWindow, Map<String, Object?>)? saveLayout;
  VoidCallback? presentationChanged;
  Widget Function(Widget)? frameBuilder;
  void Function(Object)? onError;
  Timer? _metrics;
  bool _closing = false;
  static const _displayEvents = BasicMessageChannel<String>(
    'tabryo/windows',
    StringCodec(),
  );

  ToolPresentation presentation(
    ToolWindow category,
    String owner,
    String title,
    WidgetBuilder builder,
  ) {
    final record = _presentations.putIfAbsent(
      '${category.name}:$owner',
      () => ToolPresentation(category, owner, title, builder),
    );
    record.title = title;
    record.builder = builder;
    if (!_restored.contains(category)) {
      final layout = readLayout?.call(category);
      if (layout?['detached'] == true && layout?['owner'] == owner) {
        _restored.add(category);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(detach(record));
        });
      }
    }
    return record;
  }

  Iterable<ToolPresentation> get detached =>
      _presentations.values.where((record) => record.window != null);

  void retainPresentations(Set<ToolPresentation> active) {
    _presentations.removeWhere(
      (_, record) => record.window == null && !active.contains(record),
    );
  }

  Future<void> initialize(int id) async {
    primary = id;
    _displayEvents.setMessageHandler((event) async {
      if (event == 'displaysChanged') didChangeMetrics();
      return '';
    });
    WidgetsBinding.instance.addObserver(this);
    await MultiViewDesktop.fromId(id).setPreventClose(true);
  }

  void _changed() {
    notifyListeners();
    presentationChanged?.call();
  }

  Future<void> detach(ToolPresentation record) =>
      _transition(record.category, () async {
        final existing = detached
            .where((entry) => entry.category == record.category)
            .firstOrNull;
        if (existing != null) {
          await focus(existing);
          return;
        }
        int? created;
        try {
          created = await openWindow(
            (_, _) => _ToolWindow(coordinator: this, record: record),
            options: WindowOptions(
              title: 'Tabryo · ${record.title} · ${record.owner}',
              size: const Size(960, 680),
              minimumSize: const Size(520, 360),
              shellOverrides: ViewShellOverrides(
                navigatorObservers: [record.routes],
              ),
            ),
          );
          final window = MultiViewDesktop.fromId(created);
          await window.setPreventClose(true);
          final layout = readLayout?.call(record.category) ?? {};
          final width = layout['width'], height = layout['height'];
          if (width is num &&
              height is num &&
              width.isFinite &&
              height.isFinite) {
            await window.setSize(
              Size(
                width.toDouble().clamp(520, 2400),
                height.toDouble().clamp(360, 1800),
              ),
            );
          }
          final x = layout['x'], y = layout['y'];
          if (x is num && y is num && x.isFinite && y.isFinite) {
            final oldScale = (layout['scale'] as num?)?.toDouble() ?? 1;
            final ratio = oldScale.clamp(.5, 8) / _coordinateScale(created);
            await window.setPosition(
              Offset(x.toDouble() * ratio, y.toDouble() * ratio),
            );
          }
          // Both views rebuild in one frame, allowing GlobalKey state to move.
          record.window = created;
          _changed();
          await WidgetsBinding.instance.endOfFrame;
          await NativeWebSurface.settle();
          await recoverPosition(record);
          await focus(record);
          await remember(record);
        } catch (_) {
          record.window = null;
          _changed();
          await WidgetsBinding.instance.endOfFrame;
          await NativeWebSurface.settle();
          if (created != null) {
            final window = MultiViewDesktop.fromId(created);
            await window.setPreventClose(false);
            await window.closeWindow();
          }
          rethrow;
        }
      });

  Future<void> _transition(
    ToolWindow category,
    Future<void> Function() action,
  ) {
    if (_transitions[category] case final pending?) return pending;
    final operation = Future<void>.sync(action).catchError((Object error) {
      onError?.call(error);
    });
    _transitions[category] = operation;
    unawaited(operation.whenComplete(() => _transitions.remove(category)));
    return operation;
  }

  Future<void> focus(ToolPresentation record) async {
    final id = record.window;
    if (id == null) return;
    final window = MultiViewDesktop.fromId(id);
    if (await window.isMinimized()) await window.restore();
    await recoverPosition(record);
    await window.show();
    await window.focus();
  }

  Future<void> reattach(ToolPresentation record) =>
      _transition(record.category, () async {
        final id = record.window;
        if (id == null) return;
        await remember(record, detached: false);
        record.window = null;
        record.minimized = false;
        _changed();
        await WidgetsBinding.instance.endOfFrame;
        // A native browser must leave the HWND/GTK host before that host dies.
        try {
          await NativeWebSurface.settle();
        } catch (_) {
          record.window = id;
          _changed();
          await WidgetsBinding.instance.endOfFrame;
          await NativeWebSurface.settle();
          rethrow;
        }
        final window = MultiViewDesktop.fromId(id);
        await window.setPreventClose(false);
        await window.closeWindow();
      });

  Future<void> remember(ToolPresentation record, {bool detached = true}) async {
    if (record.window == null || saveLayout == null) return;
    final window = MultiViewDesktop.fromId(record.window!);
    if (await window.isMinimized()) return;
    final bounds = await window.getBounds();
    saveLayout!(record.category, {
      'owner': record.owner,
      'detached': detached,
      'x': bounds.left,
      'y': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
      'scale': _coordinateScale(record.window!),
    });
  }

  double _coordinateScale(int id) =>
      defaultTargetPlatform == TargetPlatform.windows
      ? WidgetsBinding.instance.platformDispatcher.views
                .where((view) => view.viewId == id)
                .firstOrNull
                ?.devicePixelRatio ??
            1
      : 1;

  /// Displays use common physical coordinates on Windows. The package's window
  /// bounds use that window's scale, which can differ from the remaining monitor.
  static bool reachable(Rect bounds, List<Rect> displays, {double scale = 1}) =>
      displays.any((display) {
        final title = Rect.fromLTWH(
          bounds.left * scale,
          bounds.top * scale,
          bounds.width * scale,
          32 * scale,
        ).intersect(display);
        return title.width >= 120 * scale && title.height >= 24 * scale;
      });

  Future<void> recoverPosition(ToolPresentation record) async {
    if (record.window == null) return;
    final window = MultiViewDesktop.fromId(record.window!);
    if (await window.isMinimized()) return;
    final result = await const MethodChannel(
      'multiview_desktop/screen_retriever',
    ).invokeMapMethod<String, dynamic>('getAllDisplays');
    final displays = <Rect>[];
    for (final row in result?['displays'] as List? ?? []) {
      final position = row['visiblePosition'] as Map? ?? {'dx': 0, 'dy': 0};
      final size = row['visibleSize'] as Map? ?? row['size'] as Map;
      final scale = defaultTargetPlatform == TargetPlatform.windows
          ? (row['scaleFactor'] as num?)?.toDouble() ?? 1
          : 1.0;
      displays.add(
        Rect.fromLTWH(
          (position['dx'] as num).toDouble() * scale,
          (position['dy'] as num).toDouble() * scale,
          (size['width'] as num).toDouble() * scale,
          (size['height'] as num).toDouble() * scale,
        ),
      );
    }
    if (displays.isNotEmpty &&
        !reachable(
          await window.getBounds(),
          displays,
          scale: _coordinateScale(record.window!),
        )) {
      await window.center();
    }
  }

  @override
  void didChangeMetrics() {
    _metrics?.cancel();
    _metrics = Timer(const Duration(milliseconds: 500), () async {
      for (final record in detached.toList()) {
        try {
          await recoverPosition(record);
        } catch (error) {
          onError?.call(error);
        }
      }
    });
  }

  @override
  void onWindowEvent(int viewId, String eventName) {
    final record = detached
        .where((entry) => entry.window == viewId)
        .firstOrNull;
    if (eventName == 'close') {
      if (record != null) {
        unawaited(reattach(record));
      } else if (viewId == primary) {
        unawaited(_exit());
      }
    } else if (record != null) {
      // Windows sends process activation to minimized owned windows too.
      // Focus is not evidence that a presentation became visible again.
      if (['minimize', 'restore'].contains(eventName)) {
        record.minimized = eventName == 'minimize';
        _changed();
      }
      if (['moved', 'resized'].contains(eventName)) {
        unawaited(
          remember(record).catchError((Object error) {
            onError?.call(error);
          }),
        );
      }
    }
  }

  Future<void> _exit() async {
    if (_closing || primary == null) return;
    _closing = true;
    try {
      if (await requestExit?.call() != true) {
        await MultiViewDesktop.fromId(primary!).cancelCascadeClose();
        return;
      }
      for (final record in detached.toList()) {
        await reattach(record);
      }
      await MultiViewDesktop.fromId(primary!).setPreventClose(false);
      await MultiViewDesktop.closeApp();
    } finally {
      _closing = false;
    }
  }

  Widget slot(ToolPresentation record, {int? window, bool visible = true}) =>
      ListenableBuilder(
        listenable: this,
        builder: (context, _) {
          if (record.window != window) {
            return Center(
              child: Wrap(
                alignment: WrapAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => focus(record),
                    child: const Text('Bring to front'),
                  ),
                  TextButton(
                    onPressed: () => reattach(record),
                    child: const Text('Return to panel'),
                  ),
                ],
              ),
            );
          }
          final shown = window == null ? visible : !record.minimized;
          return TickerMode(
            enabled: shown,
            child: ExcludeFocus(
              excluding: !shown,
              child: KeyedSubtree(
                key: record.key,
                child: Builder(builder: record.builder),
              ),
            ),
          );
        },
      );

  @override
  void dispose() {
    _metrics?.cancel();
    _displayEvents.setMessageHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final class _ToolWindow extends StatelessWidget {
  const _ToolWindow({required this.coordinator, required this.record});
  final WindowCoordinator coordinator;
  final ToolPresentation record;
  @override
  Widget build(BuildContext context) {
    final surface = WebSurfaceRoutes(
      observer: record.routes,
      child: Scaffold(
        appBar: AppBar(
          title: Text(record.title),
          actions: [
            TextButton(
              onPressed: () => coordinator.reattach(record),
              child: const Text('Return to panel'),
            ),
          ],
        ),
        body: coordinator.slot(
          record,
          window: MultiViewDesktop.getIdByContext(context),
        ),
      ),
    );
    return coordinator.frameBuilder?.call(surface) ?? surface;
  }
}
