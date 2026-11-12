import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'app_state.dart';
import 'screens/connect_screen.dart';
import 'screens/home_screen.dart';
import 'screens/keyboard_screen.dart';
import 'screens/media_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/touchpad_screen.dart';
import 'services/connection_controller.dart';
import 'services/storage_service.dart';
import 'services/update_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await StorageService.open();
  final app = AppState(storage);
  final conn = ConnectionController(app);
  final update = UpdateController();
  runApp(RemoteXApp(app: app, conn: conn, update: update));
}

class RemoteXApp extends StatefulWidget {
  const RemoteXApp({super.key, required this.app, required this.conn, required this.update});

  final AppState app;
  final ConnectionController conn;
  final UpdateController update;

  @override
  State<RemoteXApp> createState() => _RemoteXAppState();
}

class _RemoteXAppState extends State<RemoteXApp> with WidgetsBindingObserver {
  static const _seed = Color(0xFF4F8CFF);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.conn.connectLast();
    widget.update.check(silent: true); // quietly look for a new version
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.conn.onResumed();
  }

  ThemeData _theme(Brightness b) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: b),
      visualDensity: VisualDensity.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      app: widget.app,
      conn: widget.conn,
      update: widget.update,
      child: ListenableBuilder(
        listenable: widget.app,
        builder: (context, _) => MaterialApp(
          title: 'Remote Mouse',
          debugShowCheckedModeBanner: false,
          themeMode: widget.app.themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: const Shell(),
        ),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  Future<void> _openConnect() async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ConnectScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(onNavigate: (i) => setState(() => _index = i), onConnect: _openConnect),
      TouchpadScreen(onConnect: _openConnect, onBack: () => setState(() => _index = 0)),
      KeyboardScreen(onConnect: _openConnect),
      MediaScreen(onConnect: _openConnect),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _index, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          AppScope.read(context).app.haptic();
          setState(() => _index = i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.touch_app_outlined), selectedIcon: Icon(Icons.touch_app_rounded), label: 'Touchpad'),
          NavigationDestination(icon: Icon(Icons.keyboard_outlined), selectedIcon: Icon(Icons.keyboard_rounded), label: 'Keyboard'),
          NavigationDestination(icon: Icon(Icons.play_circle_outline_rounded), selectedIcon: Icon(Icons.play_circle_rounded), label: 'Media'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'Settings'),
        ],
      ),
    );
  }
}
