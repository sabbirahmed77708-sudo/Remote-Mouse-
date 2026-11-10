// RemoteX wire protocol, client side. See docs/PROTOCOL.md.
//
// This file has no Flutter imports on purpose: CI runs it against the real
// Python server (test/integration/server_integration_test.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

const int kWsPort = 48766;
const int kDiscoveryPort = 48765;
const String kDiscoveryProbe = 'REMOTEX_DISCOVER_V1';

class RemoteXException implements Exception {
  RemoteXException(this.code, this.message);

  /// unreachable, timeout, certificate, bad_proof, unauthorized, locked,
  /// pairing_closed, bad_server, protocol, closed, removed
  final String code;
  final String message;

  /// Errors that retrying cannot fix.
  bool get isFatal =>
      code == 'unauthorized' ||
      code == 'certificate' ||
      code == 'removed' ||
      code == 'bad_server' ||
      code == 'bad_proof' ||
      code == 'pairing_closed';

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Crypto helpers (must match server/remotex_server/protocol.py)
// ---------------------------------------------------------------------------
String normalizeCode(String text) {
  final out = StringBuffer();
  final alnum = RegExp(r'[A-Z0-9]');
  for (final rune in text.toUpperCase().runes) {
    final ch = String.fromCharCode(rune);
    if (alnum.hasMatch(ch)) out.write(ch);
  }
  return out.toString().replaceAll('O', '0').replaceAll('I', '1').replaceAll('L', '1');
}

String toHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

List<int> fromHex(String hex) {
  final out = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}

String randomHex(int bytes) {
  final rnd = Random.secure();
  return toHex(List<int>.generate(bytes, (_) => rnd.nextInt(256)));
}

String _hmacHex(List<int> key, String message) {
  return Hmac(sha256, key).convert(utf8.encode(message)).toString();
}

String pairProof(String code, String serverNonce, String clientNonce, String deviceId, String fingerprint) {
  return _hmacHex(utf8.encode(normalizeCode(code)),
      'remotex-pair|$serverNonce|$clientNonce|$deviceId|$fingerprint');
}

String serverProof(String code, String serverNonce, String clientNonce, String deviceId, String fingerprint) {
  return _hmacHex(utf8.encode(normalizeCode(code)),
      'remotex-srv|$serverNonce|$clientNonce|$deviceId|$fingerprint');
}

String authProof(String deviceKeyHex, String serverNonce, String deviceId, String fingerprint) {
  return _hmacHex(fromHex(deviceKeyHex), 'remotex-auth|$serverNonce|$deviceId|$fingerprint');
}

String fingerprintFromB64(String text) {
  return toHex(base64Url.decode(base64Url.normalize(text)));
}

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

// ---------------------------------------------------------------------------
// Pairing link (QR code)
// ---------------------------------------------------------------------------
class PairingLink {
  PairingLink({required this.code, required this.fingerprint, required this.hosts, required this.port});

  final String code;
  final String fingerprint;
  final List<String> hosts;
  final int port;

  static PairingLink? parse(String text) {
    try {
      final uri = Uri.parse(text.trim());
      if (uri.scheme != 'remotex' || uri.host != 'pair') return null;
      final q = uri.queryParameters;
      final code = q['c'];
      final f = q['f'];
      final h = q['h'];
      if (code == null || f == null || h == null) return null;
      final fp = fingerprintFromB64(f);
      final hosts = h.split(',').where((s) => s.trim().isNotEmpty).map((s) => s.trim()).toList();
      if (fp.length != 64 || hosts.isEmpty || normalizeCode(code).length != 12) return null;
      final port = int.tryParse(q['p'] ?? '') ?? kWsPort;
      if (port < 1 || port > 65535) return null;
      return PairingLink(code: normalizeCode(code), fingerprint: fp, hosts: hosts, port: port);
    } catch (_) {
      return null;
    }
  }
}

class ServerHello {
  ServerHello({required this.id, required this.name, required this.nonce});
  final String id;
  final String name;
  final String nonce;
}

class PairResult {
  PairResult(this.connection, this.deviceKey);
  final RemoteXConnection connection;
  final String deviceKey;
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------
class RemoteXConnection {
  RemoteXConnection._(this._ws, this._http, this._iter, this.fingerprint, this.hello);

  final WebSocket _ws;
  final HttpClient _http;
  final StreamIterator<dynamic> _iter;

  /// SHA-256 of the certificate the TLS layer saw (lowercase hex).
  final String fingerprint;
  final ServerHello hello;

  int? get closeCode => _ws.closeCode;

  /// Opens a TLS WebSocket and reads the server `hello`.
  /// With [pinnedFingerprint] only that exact certificate is accepted.
  static Future<RemoteXConnection> open({
    required String host,
    required int port,
    String? pinnedFingerprint,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    String? seen;
    final http = HttpClient(context: SecurityContext(withTrustedRoots: false));
    http.connectionTimeout = timeout;
    http.badCertificateCallback = (X509Certificate cert, String h, int p) {
      final fp = sha256.convert(cert.der).toString();
      seen = fp;
      return pinnedFingerprint == null || fp == pinnedFingerprint;
    };

    WebSocket ws;
    try {
      ws = await WebSocket.connect('wss://$host:$port/ws', customClient: http)
          .timeout(timeout + const Duration(seconds: 2));
    } on HandshakeException {
      http.close(force: true);
      throw RemoteXException('certificate',
          'This is not the PC you paired with: its security certificate changed. Pair again from the PC.');
    } on TimeoutException {
      http.close(force: true);
      throw RemoteXException('timeout', 'The PC did not answer. Is RemoteX Server running, on the same Wi-Fi?');
    } on SocketException {
      http.close(force: true);
      throw RemoteXException('unreachable', 'Cannot reach $host. Check that the PC is on and on the same Wi-Fi.');
    } on WebSocketException catch (e) {
      http.close(force: true);
      throw RemoteXException('protocol', 'The PC rejected the connection (${e.message}).');
    } catch (e) {
      http.close(force: true);
      throw RemoteXException('unreachable', 'Could not connect: $e');
    }

    final it = StreamIterator<dynamic>(ws);
    try {
      final first = await _readFrom(it, timeout);
      final fp = seen;
      if (fp == null) {
        throw RemoteXException('certificate', 'Could not read the PC certificate.');
      }
      final id = first['id'];
      final nonce = first['nonce'];
      if (first['t'] != 'hello' || id is! String || nonce is! String) {
        throw RemoteXException('protocol', 'This is not a RemoteX server.');
      }
      final name = first['name'];
      return RemoteXConnection._(ws, http, it, fp, ServerHello(id: id, name: name is String ? name : 'PC', nonce: nonce));
    } catch (_) {
      try {
        await ws.close();
      } catch (_) {}
      http.close(force: true);
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> _readFrom(StreamIterator<dynamic> it, Duration timeout) async {
    final bool has;
    try {
      has = await it.moveNext().timeout(timeout);
    } on TimeoutException {
      throw RemoteXException('timeout', 'The PC did not answer in time.');
    }
    if (!has) {
      throw RemoteXException('closed', 'The PC closed the connection.');
    }
    final value = it.current;
    if (value is! String) throw RemoteXException('protocol', 'Unexpected data from the PC.');
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) throw RemoteXException('protocol', 'Unexpected data from the PC.');
    return decoded;
  }

  /// Reads one message during the handshake.
  Future<Map<String, dynamic>> read(Duration timeout) => _readFrom(_iter, timeout);

  /// All further messages. Call once, after the handshake.
  Stream<Map<String, dynamic>> messages() async* {
    while (await _iter.moveNext()) {
      final v = _iter.current;
      if (v is! String) continue;
      try {
        final m = jsonDecode(v);
        if (m is Map<String, dynamic>) yield m;
      } catch (_) {
        // ignore malformed frames
      }
    }
  }

  void send(Map<String, dynamic> message) {
    _ws.add(jsonEncode(message));
  }

  Future<void> close([int code = 1000, String reason = '']) async {
    try {
      await _ws.close(code, reason).timeout(const Duration(seconds: 2));
    } catch (_) {}
    _http.close(force: true);
  }
}

RemoteXException _fromError(Map<String, dynamic> m) {
  final code = m['code'] is String ? m['code'] as String : 'protocol';
  switch (code) {
    case 'bad_proof':
      return RemoteXException('bad_proof', 'Wrong pairing code.');
    case 'pairing_closed':
      return RemoteXException('pairing_closed',
          'The PC is not accepting pairing right now. In RemoteX Server press "New code".');
    case 'unauthorized':
      return RemoteXException('unauthorized', 'This phone is no longer paired with that PC. Pair it again.');
    case 'locked':
      return RemoteXException('locked', 'Too many failed attempts. Wait a minute and try again.');
    default:
      return RemoteXException(code, m['msg'] is String ? m['msg'] as String : 'The PC refused the connection.');
  }
}

/// First-time pairing. On success the returned connection is already open for commands.
Future<PairResult> pairWithCode({
  required String host,
  required int port,
  required String code,
  required String deviceId,
  required String deviceName,
  String? pinnedFingerprint,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final conn = await RemoteXConnection.open(
      host: host, port: port, pinnedFingerprint: pinnedFingerprint, timeout: timeout);
  try {
    final clientNonce = randomHex(16);
    conn.send({
      't': 'pair',
      'device_id': deviceId,
      'device_name': deviceName,
      'nonce': clientNonce,
      'proof': pairProof(code, conn.hello.nonce, clientNonce, deviceId, conn.fingerprint),
    });
    final reply = await conn.read(const Duration(seconds: 8));
    if (reply['t'] == 'error') throw _fromError(reply);
    final key = reply['device_key'];
    final sp = reply['server_proof'];
    if (reply['t'] != 'paired' || key is! String || key.length != 64 || sp is! String) {
      throw RemoteXException('protocol', 'Unexpected reply from the PC.');
    }
    final expected = serverProof(code, conn.hello.nonce, clientNonce, deviceId, conn.fingerprint);
    if (!constantTimeEquals(expected, sp)) {
      throw RemoteXException('bad_server',
          'This device could not prove it knows the pairing code. Connection refused for your safety.');
    }
    return PairResult(conn, key);
  } catch (_) {
    await conn.close();
    rethrow;
  }
}

/// Reconnect to an already paired PC. [fingerprint] is mandatory: only that certificate is trusted.
Future<RemoteXConnection> authenticate({
  required String host,
  required int port,
  required String fingerprint,
  required String deviceId,
  required String deviceKey,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final conn = await RemoteXConnection.open(host: host, port: port, pinnedFingerprint: fingerprint, timeout: timeout);
  try {
    conn.send({
      't': 'auth',
      'device_id': deviceId,
      'proof': authProof(deviceKey, conn.hello.nonce, deviceId, conn.fingerprint),
    });
    final reply = await conn.read(const Duration(seconds: 8));
    if (reply['t'] == 'error') throw _fromError(reply);
    if (reply['t'] != 'ready') throw RemoteXException('protocol', 'Unexpected reply from the PC.');
    return conn;
  } catch (_) {
    await conn.close();
    rethrow;
  }
}
