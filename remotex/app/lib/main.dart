import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'app_state.dart';
import 'screens/connect_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/remote_screen.dart';
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
    var scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b);
    if (b == Brightness.dark) {
      // deep blue-black surfaces, the same look as the remote screen
      scheme = scheme.copyWith(
        surface: const Color(0xFF0B0F16),
        surfaceContainerLowest: const Color(0xFF080B11),
        surfaceContainerLow: const Color(0xFF10151E),
        surfaceContainer: const Color(0xFF131923),
        surfaceContainerHigh: const Color(0xFF171D28),
        surfaceContainerHighest: const Color(0xFF222B3A),
      );
    }
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 20, fontWeight: FontWeight.w800),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35))),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.3), space: 1),
      snackBarTheme: SnackBarThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
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

/// Two pages: the connection page (saved PCs, connect) and the remote. The remote opens by itself as
/// soon as a PC is connected, and the back button returns to the connection page.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool _remote = false;
  RemotePanel _panel = RemotePanel.none;
  bool _wasConnected = false;
  ConnectionController? _conn;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_conn == null) {
      final c = AppScope.read(context).conn;
      _conn = c;
      c.addListener(_onConn);
      _wasConnected = c.connected;
      _remote = c.connected;
    }
  }

  @override
  void dispose() {
    _conn?.removeListener(_onConn);
    super.dispose();
  }

  void _onConn() {
    final c = _conn;
    if (c == null || !mounted) return;
    final now = c.connected;
    if (now && !_wasConnected) {
      setState(() {
        _remote = true;
        _panel = RemotePanel.none;
      });
    } else if (!now && _remote && !c.busy) {
      setState(() => _remote = false); // connection lost for good: back to the connection page
    }
    _wasConnected = now;
  }

  Future<void> _openConnect() async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ConnectScreen()));
  }

  void _openSettings() {
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => Scaffold(appBar: AppBar(), body: const SafeArea(child: SettingsScreen())),
    ));
  }

  /// The dashboard tiles: 1 = touchpad, 2 = keyboard, 3 = media, 4 = settings.
  void _navigate(int i) {
    if (i == 4) {
      _openSettings();
      return;
    }
    if (!(_conn?.connected ?? false)) {
      _openConnect();
      return;
    }
    setState(() {
      _panel = i == 2 ? RemotePanel.keyboard : (i == 3 ? RemotePanel.media : RemotePanel.none);
      _remote = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_remote,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _remote = false);
      },
      child: Scaffold(
        body: SafeArea(
          child: _remote
              ? RemoteScreen(
                  onConnect: _openConnect,
                  onBack: () => setState(() => _remote = false),
                  initialPanel: _panel,
                )
              : HomeScreen(onNavigate: _navigate, onConnect: _openConnect),
        ),
      ),
    );
  }
}
