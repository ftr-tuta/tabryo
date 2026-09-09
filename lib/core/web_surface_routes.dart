import 'package:flutter/material.dart';

/// Floating native views must stay hidden until a covering route finishes.
final editorRoutes = WebSurfaceRouteObserver();

final class WebSurfaceRouteObserver extends RouteObserver<ModalRoute<dynamic>> {
  Future<void> settled = Future<void>.value();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    settled = route is TransitionRoute<dynamic>
        ? route.completed.then((_) {})
        : Future<void>.value();
    super.didPop(route, previousRoute);
  }
}
