import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/services/remotex_client.dart';

/// Checks the Dart implementation against the same vectors the Python server is tested with.
void main() {
  final file = File('../protocol/test_vectors.json');
  final v = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  test('code normalisation', () {
    expect(normalizeCode(v['code_as_typed'] as String), v['code_normalized']);
    expect(normalizeCode(v['code_lookalikes_typed'] as String), v['code_lookalikes_normalized']);
  });

  test('pair proof', () {
    expect(
      pairProof(v['code_normalized'] as String, v['server_nonce'] as String, v['client_nonce'] as String,
          v['device_id'] as String, v['fingerprint'] as String),
      v['pair_proof'],
    );
  });

  test('server proof', () {
    expect(
      serverProof(v['code_normalized'] as String, v['server_nonce'] as String, v['client_nonce'] as String,
          v['device_id'] as String, v['fingerprint'] as String),
      v['server_proof'],
    );
  });

  test('auth proof', () {
    expect(
      authProof(v['device_key'] as String, v['server_nonce'] as String, v['device_id'] as String,
          v['fingerprint'] as String),
      v['auth_proof'],
    );
  });

  test('fingerprint base64url', () {
    expect(fingerprintFromB64(v['fingerprint_b64'] as String), v['fingerprint']);
  });

  test('pairing link parsing', () {
    final fp = v['fingerprint_b64'] as String;
    final link = PairingLink.parse('remotex://pair?c=ABCD-EFGH-JKMN&f=$fp&h=192.168.1.5,10.0.0.2');
    expect(link, isNotNull);
    expect(link!.code, 'ABCDEFGHJKMN');
    expect(link.hosts, ['192.168.1.5', '10.0.0.2']);
    expect(link.port, kWsPort);
    expect(link.fingerprint, v['fingerprint']);
  });

  test('pairing link rejects garbage', () {
    final fp = v['fingerprint_b64'] as String;
    expect(PairingLink.parse('https://example.com'), isNull);
    expect(PairingLink.parse('remotex://pair?c=SHORT&f=$fp&h=1.2.3.4'), isNull);
    expect(PairingLink.parse('remotex://pair?c=ABCDEFGHJKMN&f=zz&h=1.2.3.4'), isNull);
    expect(PairingLink.parse('remotex://pair?c=ABCDEFGHJKMN&f=$fp'), isNull);
    expect(PairingLink.parse('remotex://pair?c=ABCDEFGHJKMN&f=$fp&h=1.2.3.4&p=99999'), isNull);
  });
}
