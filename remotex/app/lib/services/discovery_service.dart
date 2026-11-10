import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/saved_pc.dart';
import 'remotex_client.dart';

/// Finds RemoteX servers on the Wi-Fi network: broadcasts a probe over UDP and
/// collects the unicast answers. Answers carry no secrets and authorise nothing.
Future<List<DiscoveredPc>> discoverPcs({Duration timeout = const Duration(milliseconds: 2500)}) async {
  RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  } catch (_) {
    return [];
  }
  socket.broadcastEnabled = true;
  final found = <String, DiscoveredPc>{};

  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    var datagram = socket.receive();
    while (datagram != null) {
      try {
        final msg = jsonDecode(utf8.decode(datagram.data));
        if (msg is Map && msg['t'] == 'remotex') {
          final id = msg['id'];
          final name = msg['name'];
          final port = msg['port'];
          if (id is String && name is String && port is int && port > 0 && port < 65536) {
            found[id] = DiscoveredPc(id: id, name: name, host: datagram.address.address, port: port);
          }
        }
      } catch (_) {
        // not a RemoteX answer
      }
      datagram = socket.receive();
    }
  });

  final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    for (final nic in interfaces) {
      for (final addr in nic.addresses) {
        final parts = addr.address.split('.');
        if (parts.length == 4) {
          targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    }
  } catch (_) {
    // fall back to the global broadcast address only
  }

  final probe = utf8.encode(kDiscoveryProbe);
  for (var round = 0; round < 3; round++) {
    for (final target in targets) {
      try {
        socket.send(probe, target, kDiscoveryPort);
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  final rest = timeout - const Duration(milliseconds: 1200);
  if (rest > Duration.zero) await Future<void>.delayed(rest);

  await sub.cancel();
  socket.close();
  final list = found.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}
