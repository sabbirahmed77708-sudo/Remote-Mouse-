import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_pc.dart';
import 'remotex_client.dart';

/// Thin wrapper over SharedPreferences: settings, this phone's identity and the saved PCs.
class StorageService {
  StorageService._(this._prefs);

  final SharedPreferences _prefs;

  static Future<StorageService> open() async => StorageService._(await SharedPreferences.getInstance());

  /// Test hook.
  static StorageService withPrefs(SharedPreferences prefs) => StorageService._(prefs);

  String get deviceId {
    var id = _prefs.getString('deviceId');
    if (id == null || id.length != 32) {
      id = randomHex(16);
      _prefs.setString('deviceId', id);
    }
    return id;
  }

  String get deviceName => _prefs.getString('deviceName') ?? 'Android phone';
  set deviceName(String v) => _prefs.setString('deviceName', v);

  int get themeMode => _prefs.getInt('themeMode') ?? 0; // 0 system, 1 light, 2 dark
  set themeMode(int v) => _prefs.setInt('themeMode', v);

  double get pointerSpeed => _prefs.getDouble('pointerSpeed') ?? 1.6;
  set pointerSpeed(double v) => _prefs.setDouble('pointerSpeed', v);

  double get scrollSpeed => _prefs.getDouble('scrollSpeed') ?? 1.0;
  set scrollSpeed(double v) => _prefs.setDouble('scrollSpeed', v);

  bool get naturalScroll => _prefs.getBool('naturalScroll') ?? true;
  set naturalScroll(bool v) => _prefs.setBool('naturalScroll', v);

  bool get haptics => _prefs.getBool('haptics') ?? true;
  set haptics(bool v) => _prefs.setBool('haptics', v);

  bool get autoReconnect => _prefs.getBool('autoReconnect') ?? true;
  set autoReconnect(bool v) => _prefs.setBool('autoReconnect', v);

  /// The PC to reconnect to automatically when the app starts (id), if any.
  String? get lastPcId => _prefs.getString('lastPcId');
  set lastPcId(String? v) {
    if (v == null) {
      _prefs.remove('lastPcId');
    } else {
      _prefs.setString('lastPcId', v);
    }
  }

  List<SavedPc> loadPcs() => SavedPc.decodeList(_prefs.getString('pcs'));

  Future<void> savePcs(List<SavedPc> pcs) async {
    await _prefs.setString('pcs', SavedPc.encodeList(pcs));
  }
}
