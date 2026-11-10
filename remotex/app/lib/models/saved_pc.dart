import 'dart:convert';

/// A PC this phone has paired with (kept on the phone, including the secret device key).
class SavedPc {
  const SavedPc({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.deviceKey,
    required this.lastConnected,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String fingerprint;
  final String deviceKey;
  final int lastConnected; // milliseconds since epoch

  SavedPc copyWith({String? name, String? host, int? port, int? lastConnected}) => SavedPc(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        fingerprint: fingerprint,
        deviceKey: deviceKey,
        lastConnected: lastConnected ?? this.lastConnected,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'fingerprint': fingerprint,
        'deviceKey': deviceKey,
        'lastConnected': lastConnected,
      };

  static SavedPc? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final host = raw['host'];
    final port = raw['port'];
    final fp = raw['fingerprint'];
    final key = raw['deviceKey'];
    if (id is! String || name is! String || host is! String || port is! int || fp is! String || key is! String) {
      return null;
    }
    final last = raw['lastConnected'];
    return SavedPc(
      id: id,
      name: name,
      host: host,
      port: port,
      fingerprint: fp,
      deviceKey: key,
      lastConnected: last is int ? last : 0,
    );
  }

  static String encodeList(List<SavedPc> pcs) => jsonEncode(pcs.map((p) => p.toJson()).toList());

  static List<SavedPc> decodeList(String? text) {
    if (text == null || text.isEmpty) return [];
    try {
      final raw = jsonDecode(text);
      if (raw is! List) return [];
      return raw.map(SavedPc.fromJson).whereType<SavedPc>().toList();
    } catch (_) {
      return [];
    }
  }
}

/// A PC found by the UDP broadcast (nothing is trusted from this).
class DiscoveredPc {
  const DiscoveredPc({required this.id, required this.name, required this.host, required this.port});
  final String id;
  final String name;
  final String host;
  final int port;
}
