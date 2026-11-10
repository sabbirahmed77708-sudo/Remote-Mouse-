import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models/saved_pc.dart';
import 'discovery_service.dart';
import 'remotex_client.dart';

enum LinkState { idle, connecting, connected, reconnecting, failed }

/// Owns the live connection: pairing, authentication, heartbeat, automatic
/// reconnection, and the typed command API used by the screens.
class ConnectionController extends ChangeNotifier {
  ConnectionController(this.app);

  final AppState app;

  LinkState state = LinkState.idle;
  SavedPc? pc;
  String? error;
  int? latencyMs;

  RemoteXConnection? _conn;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _heartbeat;
  DateTime _lastPong = DateTime.now();
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
  }

  void _onMessage(RemoteXConnection conn, Map<String, dynamic> m) {
    if (conn != _conn) return;
    if (m['t'] == 'pong') {
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

  Future<void> _dropConnection() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    final sub = _sub;
    _sub = null;
    final conn = _conn;
    _conn = null;
    latencyMs = null;
    await sub?.cancel();
    if (conn != null) {
      try {
        conn.send({'t': 'bye'});
      } catch (_) {}
      await conn.close();
    }
  }

  // -------------------------------------------------------------------------
  // Commands (silently ignored while not connected)
  // -------------------------------------------------------------------------
  void _send(Map<String, dynamic> m) {
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

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _heartbeat?.cancel();
    unawaited(_sub?.cancel());
    final c = _conn;
    _conn = null;
    if (c != null) unawaited(c.close());
    super.dispose();
  }
}
