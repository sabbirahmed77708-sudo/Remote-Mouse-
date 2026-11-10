import 'package:flutter/widgets.dart';

import 'app_state.dart';
import 'services/connection_controller.dart';

/// Gives every screen access to the settings and the live connection.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.app, required this.conn, required super.child});

  final AppState app;
  final ConnectionController conn;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing above this widget');
    return scope!;
  }

  /// For event handlers (does not subscribe to changes).
  static AppScope read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing above this widget');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => app != oldWidget.app || conn != oldWidget.conn;
}
