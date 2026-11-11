import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/services/remotex_client.dart';

/// Real Dart client against the real Python server (dry-run input, so nothing moves).
/// Needs Python with the server requirements; skipped when REMOTEX_SERVER_CMD is unset.
///   REMOTEX_SERVER_CMD="python ../server/run_server.py"
void main() {
  final cmd = Platform.environment['REMOTEX_SERVER_CMD'];
  if (cmd == null || cmd.isEmpty) {
    test('server integration (set REMOTEX_SERVER_CMD to run)', () {}, skip: 'REMOTEX_SERVER_CMD not set');
    return;
  }

  late Process proc;
  late Directory dir;
  late Map<String, dynamic> ready;
  final events = <Map<String, dynamic>>[];
  final waiters = <_Waiter>[];

  Future<Map<String, dynamic>> waitFor(bool Function(Map<String, dynamic>) test,
      {Duration timeout = const Duration(seconds: 8)}) {
    for (final e in events) {
      if (test(e)) return Future.value(e);
    }
    final w = _Waiter(test);
    waiters.add(w);
    return w.completer.future.timeout(timeout, onTimeout: () {
      waiters.remove(w);
      throw TimeoutException('event not seen; got: ${jsonEncode(events)}');
    });
  }

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('remotex-it-');
    final port = await _freePort();
    final parts = cmd.split(' ');
    proc = await Process.start(parts.first, [
      ...parts.skip(1),
      '--headless',
      '--dry-run-input',
      '--auto-approve-requests',
      '--json-events',
      '--port',
      '$port',
      '--data-dir',
      dir.path,
      '--name',
      'IT-PC',
    ]);
    proc.stderr.transform(utf8.decoder).listen((s) => stderr.write(s));
    final readyC = Completer<Map<String, dynamic>>();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        events.add(m);
        if (m['event'] == 'ready' && !readyC.isCompleted) readyC.complete(m);
        for (final w in List.of(waiters)) {
          if (w.test(m)) {
            waiters.remove(w);
            w.completer.complete(m);
          }
        }
      } catch (_) {}
    });
    ready = await readyC.future.timeout(const Duration(seconds: 30));
  });

  tearDownAll(() async {
    proc.kill();
    await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  const host = '127.0.0.1';
  int port() => ready['port'] as int;
  String code() => ready['code'] as String;
  String fp() => ready['fingerprint'] as String;
  final deviceId = randomHex(16);
  late String deviceKey;

  test('pairing link from the server parses and matches its certificate', () {
    final link = PairingLink.parse(ready['uri'] as String);
    expect(link, isNotNull);
    expect(link!.fingerprint, fp());
    expect(link.code, normalizeCode(code()));
  });

  test('wrong fingerprint is refused before anything is sent', () async {
    await expectLater(
      pairWithCode(
        host: host,
        port: port(),
        code: code(),
        deviceId: randomHex(16),
        deviceName: 'bad',
        pinnedFingerprint: 'ab' * 32,
      ),
      throwsA(isA<RemoteXException>().having((e) => e.code, 'code', 'certificate')),
    );
  });

  test('wrong code is refused', () async {
    await expectLater(
      pairWithCode(
        host: host,
        port: port(),
        code: 'ZZZZZZZZZZZZ',
        deviceId: randomHex(16),
        deviceName: 'bad',
        pinnedFingerprint: fp(),
      ),
      throwsA(isA<RemoteXException>().having((e) => e.code, 'code', 'bad_proof')),
    );
  });

  test('pair with pinned fingerprint, then send every command type', () async {
    final r = await pairWithCode(
      host: host,
      port: port(),
      code: code(),
      deviceId: deviceId,
      deviceName: 'Dart IT',
      pinnedFingerprint: fp(),
    );
    deviceKey = r.deviceKey;
    final c = r.connection;
    expect(c.fingerprint, fp());
    // keep the stream drained
    final sub = c.messages().listen((_) {});
    c.send({'t': 'move', 'dx': 7, 'dy': -3});
    c.send({'t': 'click', 'b': 'left', 'n': 2});
    c.send({'t': 'btn', 'b': 'right', 'd': true});
    c.send({'t': 'scroll', 'dx': 0, 'dy': 120});
    c.send({'t': 'text', 's': 'hello'});
    c.send({'t': 'key', 'k': 'enter', 'n': 1});
    c.send({'t': 'combo', 'k': ['ctrl', 'c']});
    c.send({'t': 'media', 'k': 'playpause'});
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'move' && e['dx'] == 7 && e['dy'] == -3);
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'click' && e['b'] == 'left' && e['n'] == 2);
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'btn' && e['b'] == 'right' && e['d'] == true);
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'scroll' && e['dy'] == 120);
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'text' && e['s'] == 'hello');
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'key' && e['k'] == 'enter');
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'combo' && (e['k'] as List).join('+') == 'ctrl+c');
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'media' && e['k'] == 'playpause');
    await c.close();
    await sub.cancel().timeout(const Duration(seconds: 2), onTimeout: () {});
  });

  test('pair with Allow (no code): same check number, key works afterwards', () async {
    final id = randomHex(16);
    String? sas;
    final r = await requestPairing(
      host: host,
      port: port(),
      deviceId: id,
      deviceName: 'Allow phone',
      onWaiting: (s) => sas = s,
    );
    expect(sas, matches(RegExp(r'^\d{6}$')));
    final req = await waitFor((e) => e['event'] == 'request' && e['device_id'] == id);
    expect(req['sas'], sas); // PC and phone show the same number
    expect(r.connection.fingerprint, fp());
    final sub = r.connection.messages().listen((_) {});
    r.connection.send({'t': 'move', 'dx': 11, 'dy': 12});
    await waitFor((e) => e['event'] == 'input' && e['op'] == 'move' && e['dx'] == 11);
    await r.connection.close();
    await sub.cancel().timeout(const Duration(seconds: 2), onTimeout: () {});
    final again = await authenticate(host: host, port: port(), fingerprint: fp(), deviceId: id, deviceKey: r.deviceKey);
    await again.close();
  });

  test('reconnect with the stored key (auth) and ping/pong', () async {
    final c = await authenticate(
      host: host,
      port: port(),
      fingerprint: fp(),
      deviceId: deviceId,
      deviceKey: deviceKey,
    );
    final pong = Completer<void>();
    final sub = c.messages().listen((m) {
      if (m['t'] == 'pong' && !pong.isCompleted) pong.complete();
    });
    c.send({'t': 'ping', 'ts': 1});
    await pong.future.timeout(const Duration(seconds: 5));
    await c.close();
    await sub.cancel().timeout(const Duration(seconds: 2), onTimeout: () {});
  });

  test('auth with a wrong key is refused', () async {
    await expectLater(
      authenticate(host: host, port: port(), fingerprint: fp(), deviceId: deviceId, deviceKey: '00' * 32),
      throwsA(isA<RemoteXException>().having((e) => e.code, 'code', 'unauthorized')),
    );
  });

  test('commands before authentication are not executed', () async {
    final c = await RemoteXConnection.open(host: host, port: port(), pinnedFingerprint: fp());
    final before = events.where((e) => e['event'] == 'input').length;
    c.send({'t': 'move', 'dx': 99, 'dy': 99});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(events.where((e) => e['event'] == 'input').length, before);
    await c.close();
  });
}

class _Waiter {
  _Waiter(this.test);
  final bool Function(Map<String, dynamic>) test;
  final Completer<Map<String, dynamic>> completer = Completer();
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}
