import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models/saved_pc.dart';
import 'bluetooth_hid.dart';
import 'discovery_service.dart';
import 'remotex_client.dart';

enum LinkState { idle, connecting, connected, reconnecting, failed }

/// One window on the PC that has a taskbar button (see "Open windows and apps" in PROTOCOL.md).
class RemoteWindow {
  const RemoteWindow({required this.id, required this.title, required this.app, required this.minimized});

  final int id;
  final String title;

  /// Lower-case exe file name, e.g. "chrome.exe". Also the key of the icon.
  final String app;
  final bool minimized;

  /// "chrome.exe" -> "Chrome"
  String get appName => appDisplayName(app);

  @override
  bool operator ==(Object other) =>
      other is RemoteWindow && other.id == id && other.title == title && other.app == app && other.minimized == minimized;

  @override
  int get hashCode => Object.hash(id, title, app, minimized);
}

String appDisplayName(String app) {
  var n = app.toLowerCase().endsWith('.exe') ? app.substring(0, app.length - 4) : app;
  if (n.isEmpty) return 'App';
  n = n.replaceAll(RegExp(r'[_\-]+'), ' ');
  return n[0].toUpperCase() + n.substring(1);
}

/// Reads the `items` of a `windows` message; entries that are not well formed are skipped.
List<RemoteWindow> parseWindows(Object? items) {
  final out = <RemoteWindow>[];
  if (items is! List) return out;
  for (final e in items) {
    if (e is! Map) continue;
    final id = e['id'], title = e['title'], app = e['app'];
    if (id is int && title is String && app is String) {
      out.add(RemoteWindow(id: id, title: title, app: app, minimized: e['min'] == true));
    }
  }
  return out;
}

/// Owns the live connection: pairing, authentication, heartbeat, automatic
/// reconnection, and the typed command API used by the screens.
class ConnectionController extends ChangeNotifier {
  ConnectionController(this.app) {
    bt.addListener(_onBluetooth);
  }

  /// Bluetooth link: the phone acts as a Bluetooth mouse/keyboard, nothing is needed on the PC.
  final BluetoothHid bt = BluetoothHid();
  bool viaBluetooth = false;

  final AppState app;

  LinkState state = LinkState.idle;
  SavedPc? pc;
  String? error;
  int? latencyMs;

  /// While waiting for "Allow" on the PC: the number both screens must show.
  String? waitingSas;
  RemoteXConnection? _pairingConn;

  RemoteXConnection? _conn;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _heartbeat;
  DateTime _lastPong = DateTime.now();

  /// Windows open on the PC (refreshed every 2 s while connected over Wi-Fi) and the one in front (0 = none).
  List<RemoteWindow> windows = const [];
  int foregroundId = 0;

  /// App icons by app key (PNG bytes). An empty list means "the PC has no icon for it".
  final Map<String, Uint8List> icons = {};
  final Set<String> _iconAsked = {};
  String? _iconsForPc;
  Timer? _windowTimer;

  RemoteWindow? get foreground {
    for (final w in windows) {
      if (w.id == foregroundId) return w;
    }
    return null;
  }

  bool _wantConnected = false;
  int _generation = 0;
  bool _disposed = false;

  bool get connected => state == LinkState.connected;
  bool get busy => state == LinkState.connecting || state == LinkState.reconnecting;

  void _set(LinkState s) {
    state = s;
    if (!_disposed) notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Connecting
  // -------------------------------------------------------------------------

  /// Connect to a PC that is already paired.
  Future<bool> connectSaved(SavedPc target) async {
    final gen = ++_generation;
    await _dropConnection();
    pc = target;
    error = null;
    _wantConnected = true;
    _set(LinkState.connecting);
    try {
      final conn = await _authenticateWithFallback(target);
      if (gen != _generation) {
        await conn.close();
        return false;
      }
      _attach(conn, pc ?? target);
      return true;
    } on RemoteXException catch (e) {
      if (gen != _generation) return false;
      _fail(e);
      return false;
    }
  }

  /// First-time pairing from a scanned QR code.
  Future<bool> pairWithLink(PairingLink link) {
    return _pair(hosts: link.hosts, port: link.port, code: link.code, pinned: link.fingerprint);
  }

  /// First-time pairing by typing the PC address and the code shown on the PC.
  Future<bool> pairManual({required String host, required int port, required String code}) {
    return _pair(hosts: [host], port: port, code: code, pinned: null);
  }

  /// First-time pairing without a code: the PC owner presses Allow.
  Future<bool> pairByAllow({required String host, required int port}) async {
    final gen = ++_generation;
    await _dropConnection();
    error = null;
    waitingSas = null;
    _wantConnected = false;
    _set(LinkState.connecting);
    try {
      final result = await requestPairing(
        host: host,
        port: port,
        deviceId: app.deviceId,
        deviceName: app.deviceName,
        onConnection: (c) => _pairingConn = c,
        onWaiting: (sas) {
          if (gen != _generation) return;
          waitingSas = sas;
          notifyListeners();
        },
      );
      _pairingConn = null;
      if (gen != _generation) {
        await result.connection.close();
        return false;
      }
      final conn = result.connection;
      final saved = SavedPc(
        id: conn.hello.id,
        name: conn.hello.name,
        host: host,
        port: port,
        fingerprint: conn.fingerprint,
        deviceKey: result.deviceKey,
        lastConnected: DateTime.now().millisecondsSinceEpoch,
      );
      await app.upsertPc(saved);
      waitingSas = null;
      _wantConnected = true;
      _attach(conn, saved);
      return true;
    } on RemoteXException catch (e) {
      _pairingConn = null;
      if (gen == _generation) {
        waitingSas = null;
        _fail(e);
      }
      return false;
    }
  }

  Future<bool> _pair({
    required List<String> hosts,
    required int port,
    required String code,
    required String? pinned,
  }) async {
    final gen = ++_generation;
    await _dropConnection();
    error = null;
    _wantConnected = false;
    _set(LinkState.connecting);
    RemoteXException? last;
    for (final host in hosts) {
      try {
        final result = await pairWithCode(
          host: host,
          port: port,
          code: code,
          deviceId: app.deviceId,
          deviceName: app.deviceName,
          pinnedFingerprint: pinned,
        );
        if (gen != _generation) {
          await result.connection.close();
          return false;
        }
        final conn = result.connection;
        final saved = SavedPc(
          id: conn.hello.id,
          name: conn.hello.name,
          host: host,
          port: port,
          fingerprint: conn.fingerprint,
          deviceKey: result.deviceKey,
          lastConnected: DateTime.now().millisecondsSinceEpoch,
        );
        await app.upsertPc(saved);
        _wantConnected = true;
        _attach(conn, saved);
        return true;
      } on RemoteXException catch (e) {
        last = e;
        final tryNext = e.code == 'unreachable' || e.code == 'timeout' || e.code == 'certificate';
        if (!tryNext) break;
      }
    }
    if (gen == _generation && last != null) _fail(last);
    return false;
  }

  Future<RemoteXConnection> _authenticateWithFallback(SavedPc target) async {
    try {
      return await authenticate(
        host: target.host,
        port: target.port,
        fingerprint: target.fingerprint,
        deviceId: app.deviceId,
        deviceKey: target.deviceKey,
      );
    } on RemoteXException catch (e) {
      if (e.code != 'unreachable' && e.code != 'timeout') rethrow;
      // The PC may have a new address (DHCP). Look for it by its id.
      final found = await discoverPcs(timeout: const Duration(milliseconds: 1800));
      DiscoveredPc? match;
      for (final d in found) {
        if (d.id == target.id) match = d;
      }
      if (match == null) rethrow;
      final conn = await authenticate(
        host: match.host,
        port: match.port,
        fingerprint: target.fingerprint,
        deviceId: app.deviceId,
        deviceKey: target.deviceKey,
      );
      final updated = target.copyWith(host: match.host, port: match.port);
      pc = updated;
      await app.upsertPc(updated);
      return conn;
    }
  }

  void _attach(RemoteXConnection conn, SavedPc target) {
    _conn = conn;
    pc = target;
    error = null;
    latencyMs = null;
    _lastPong = DateTime.now();
    final updated = target.copyWith(lastConnected: DateTime.now().millisecondsSinceEpoch);
    pc = updated;
    app.storage.lastPcId = updated.id;
    unawaited(app.upsertPc(updated));
    _set(LinkState.connected);
    _sub = conn.messages().listen(
          (m) => _onMessage(conn, m),
          onDone: () => _onClosed(conn),
          onError: (Object _) => _onClosed(conn),
          cancelOnError: true,
        );
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) => _beat(conn));
    _beat(conn);
    _iconAsked.clear(); // ask again after a reconnect: an earlier request may have been lost
    if (_iconsForPc != updated.id) {
      icons.clear(); // icons belong to one PC
      _iconsForPc = updated.id;
    }
    _windowTimer?.cancel();
    _windowTimer = Timer.periodic(const Duration(seconds: 2), (_) => refreshWindows());
    refreshWindows();
  }

  void _stopWindowPolling() {
    _windowTimer?.cancel();
    _windowTimer = null;
    windows = const [];
    foregroundId = 0;
  }

  void _onMessage(RemoteXConnection conn, Map<String, dynamic> m) {
    if (conn != _conn) return;
    if (m['t'] == 'windows') {
      final list = parseWindows(m['items']);
      final fg = m['fg'] is int ? m['fg'] as int : 0;
      if (fg != foregroundId || !listEquals(list, windows)) {
        windows = list;
        foregroundId = fg;
        notifyListeners();
      }
      for (final w in list) {
        if (icons.containsKey(w.app) || !_iconAsked.add(w.app)) continue;
        _send({'t': 'icon', 'k': w.app});
      }
    } else if (m['t'] == 'icon') {
      final key = m['k'], png = m['png'];
      if (key is! String) return;
      try {
        icons[key] = png is String ? base64Decode(png) : Uint8List(0);
      } catch (_) {
        icons[key] = Uint8List(0);
      }
      notifyListeners();
    } else if (m['t'] == 'pong') {
      _lastPong = DateTime.now();
      final ts = m['ts'];
      if (ts is int) {
        final rtt = DateTime.now().millisecondsSinceEpoch - ts;
        latencyMs = rtt < 0 ? 0 : rtt;
        notifyListeners();
      }
    }
  }

  void _beat(RemoteXConnection conn) {
    if (conn != _conn) return;
    if (DateTime.now().difference(_lastPong) > const Duration(seconds: 12)) {
      // The PC has gone silent (Wi-Fi dropped, PC asleep...). Treat as lost.
      unawaited(conn.close(4008, 'timeout'));
      _onClosed(conn);
      return;
    }
    try {
      conn.send({'t': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
    } catch (_) {
      _onClosed(conn);
    }
  }

  void _onClosed(RemoteXConnection conn) {
    if (conn != _conn) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    _stopWindowPolling();
    unawaited(_sub?.cancel());
    _sub = null;
    _conn = null;
    latencyMs = null;
    final code = conn.closeCode;
    if (code == 4003) {
      _wantConnected = false;
      error = 'The PC disconnected this phone.';
      _set(LinkState.idle);
    } else if (_wantConnected && app.autoReconnect && pc != null) {
      unawaited(_reconnectLoop());
    } else {
      _set(LinkState.idle);
    }
  }

  Future<void> _reconnectLoop() async {
    final gen = ++_generation;
    var delay = 1;
    _set(LinkState.reconnecting);
    while (_wantConnected && gen == _generation && !_disposed) {
      final target = pc;
      if (target == null) break;
      try {
        final conn = await _authenticateWithFallback(target);
        if (gen != _generation || !_wantConnected) {
          await conn.close();
          return;
        }
        _attach(conn, pc ?? target);
        return;
      } on RemoteXException catch (e) {
        if (gen != _generation) return;
        if (e.isFatal) {
          _fail(e);
          return;
        }
        error = e.message;
        if (!_disposed) notifyListeners();
        final wait = e.code == 'locked' ? 30 : delay;
        await Future<void>.delayed(Duration(seconds: wait));
        delay = min(delay * 2, 10);
      }
    }
  }

  void _fail(RemoteXException e) {
    error = e.message;
    if (e.isFatal) _wantConnected = false;
    _set(LinkState.failed);
  }

  /// The user left the app and came back: make sure we are connected again.
  void onResumed() {
    if (_disposed) return;
    final conn = _conn;
    if (conn != null) {
      _beat(conn); // detects a dead socket quickly
    } else if (_wantConnected && app.autoReconnect && !busy && pc != null) {
      unawaited(_reconnectLoop());
    }
  }

  /// Reconnect to the PC used last time (called once when the app starts).
  Future<void> connectLast() async {
    final id = app.storage.lastPcId;
    if (id == null || !app.autoReconnect) return;
    final target = app.pcById(id);
    if (target != null) await connectSaved(target);
  }

  Future<void> disconnect() async {
    _generation++;
    _wantConnected = false;
    await _dropConnection();
    error = null;
    _set(LinkState.idle);
  }

  void _onBluetooth() {
    if (_disposed) return;
    if (bt.connected && !viaBluetooth) {
      // a Wi-Fi link (if any) is replaced by the Bluetooth one
      unawaited(() async {
        _generation++;
        _wantConnected = false;
        await _dropConnection();
        viaBluetooth = true;
        error = null;
        pc = SavedPc(
          id: 'bt:${bt.connectedAddress}',
          name: bt.connectedName ?? 'PC',
          host: 'Bluetooth',
          port: 0,
          fingerprint: '',
          deviceKey: '',
          lastConnected: DateTime.now().millisecondsSinceEpoch,
        );
        _set(LinkState.connected);
      }());
    } else if (!bt.connected && viaBluetooth) {
      viaBluetooth = false;
      pc = null;
      _set(LinkState.idle);
    }
  }

  Future<void> _dropConnection() async {
    if (viaBluetooth) {
      viaBluetooth = false;
      pc = null;
      unawaited(bt.disconnect());
    }
    _heartbeat?.cancel();
    _heartbeat = null;
    _stopWindowPolling();
    final sub = _sub;
    _sub = null;
    final pairing = _pairingConn;
    _pairingConn = null;
    waitingSas = null;
    if (pairing != null) unawaited(pairing.close());
    final conn = _conn;
    _conn = null;
    latencyMs = null;
    // Close the socket first: cancelling an async* stream that is waiting for the
    // next frame would otherwise wait for that frame.
    if (conn != null) {
      try {
        conn.send({'t': 'bye'});
      } catch (_) {}
      await conn.close();
    }
    if (sub != null) {
      try {
        await sub.cancel().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------------
  // Commands (silently ignored while not connected)
  // -------------------------------------------------------------------------
  void _send(Map<String, dynamic> m) {
    if (viaBluetooth) {
      if (bt.connected) bt.handle(m);
      return;
    }
    final c = _conn;
    if (c == null || state != LinkState.connected) return;
    try {
      c.send(m);
    } catch (_) {
      _onClosed(c);
    }
  }

  void move(int dx, int dy) => _send({'t': 'move', 'dx': dx, 'dy': dy});
  void click(String button, {int count = 1}) => _send({'t': 'click', 'b': button, 'n': count});
  void button(String button, bool down) => _send({'t': 'btn', 'b': button, 'd': down});
  void scroll(int dx, int dy) => _send({'t': 'scroll', 'dx': dx, 'dy': dy});
  void typeText(String text) {
    // the server accepts up to 500 characters per message
    final runes = text.runes.toList();
    for (var i = 0; i < runes.length; i += 400) {
      _send({'t': 'text', 's': String.fromCharCodes(runes.sublist(i, min(i + 400, runes.length)))});
    }
  }

  void key(String name, {int count = 1}) => _send({'t': 'key', 'k': name, 'n': count});
  void combo(List<String> keys) => _send({'t': 'combo', 'k': keys});
  void media(String name) => _send({'t': 'media', 'k': name});

  /// Asks the PC for its open windows (the answer arrives as a `windows` message). Wi-Fi link only.
  void refreshWindows() {
    if (viaBluetooth || state != LinkState.connected) return;
    _send({'t': 'windows'});
  }

  /// action: focus, close, min, max or restore.
  void windowAction(String action, int id) {
    if (action == 'close') {
      // disappear at once; if the app asks to save first, the next refresh brings it back
      windows = [for (final w in windows) if (w.id != id) w];
      notifyListeners();
    }
    _send({'t': 'win', 'a': action, 'id': id});
    Future<void>.delayed(const Duration(milliseconds: 350), refreshWindows);
    Future<void>.delayed(const Duration(milliseconds: 1200), refreshWindows);
  }

  /// Starts one of the apps the PC allows (see LAUNCH names in PROTOCOL.md).
  void launch(String name) {
    _send({'t': 'launch', 'k': name});
    Future<void>.delayed(const Duration(milliseconds: 900), refreshWindows);
    Future<void>.delayed(const Duration(milliseconds: 2500), refreshWindows);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _windowTimer?.cancel();
    _heartbeat?.cancel();
    unawaited(_sub?.cancel());
    final c = _conn;
    _conn = null;
    if (c != null) unawaited(c.close());
    bt.removeListener(_onBluetooth);
    bt.dispose();
    super.dispose();
  }
}
