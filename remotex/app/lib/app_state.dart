import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/saved_pc.dart';
import 'services/storage_service.dart';

/// Settings + saved PCs. Everything is persisted immediately.
class AppState extends ChangeNotifier {
  AppState(this.storage)
      : _themeMode = storage.themeMode,
        _pointerSpeed = storage.pointerSpeed,
        _scrollSpeed = storage.scrollSpeed,
        _naturalScroll = storage.naturalScroll,
        _haptics = storage.haptics,
        _autoReconnect = storage.autoReconnect,
        _deviceName = storage.deviceName,
        _pcs = storage.loadPcs();

  final StorageService storage;

  int _themeMode;
  double _pointerSpeed;
  double _scrollSpeed;
  bool _naturalScroll;
  bool _haptics;
  bool _autoReconnect;
  String _deviceName;
  List<SavedPc> _pcs;

  String get deviceId => storage.deviceId;

  ThemeMode get themeMode => const [ThemeMode.system, ThemeMode.light, ThemeMode.dark][_themeMode];
  set themeMode(ThemeMode m) {
    _themeMode = m.index;
    storage.themeMode = _themeMode;
    notifyListeners();
  }

  double get pointerSpeed => _pointerSpeed;
  set pointerSpeed(double v) {
    _pointerSpeed = v;
    storage.pointerSpeed = v;
    notifyListeners();
  }

  double get scrollSpeed => _scrollSpeed;
  set scrollSpeed(double v) {
    _scrollSpeed = v;
    storage.scrollSpeed = v;
    notifyListeners();
  }

  bool get naturalScroll => _naturalScroll;
  set naturalScroll(bool v) {
    _naturalScroll = v;
    storage.naturalScroll = v;
    notifyListeners();
  }

  bool get haptics => _haptics;
  set haptics(bool v) {
    _haptics = v;
    storage.haptics = v;
    notifyListeners();
  }

  bool get autoReconnect => _autoReconnect;
  set autoReconnect(bool v) {
    _autoReconnect = v;
    storage.autoReconnect = v;
    notifyListeners();
  }

  String get deviceName => _deviceName;
  set deviceName(String v) {
    final cleaned = v.trim();
    _deviceName = cleaned.isEmpty ? 'Android phone' : cleaned;
    storage.deviceName = _deviceName;
    notifyListeners();
  }

  List<SavedPc> get pcs => List.unmodifiable(_pcs);

  SavedPc? pcById(String id) {
    for (final p in _pcs) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> upsertPc(SavedPc pc) async {
    final next = [..._pcs.where((p) => p.id != pc.id), pc]
      ..sort((a, b) => b.lastConnected.compareTo(a.lastConnected));
    _pcs = next;
    await storage.savePcs(_pcs);
    notifyListeners();
  }

  Future<void> removePc(String id) async {
    _pcs = _pcs.where((p) => p.id != id).toList();
    await storage.savePcs(_pcs);
    if (storage.lastPcId == id) storage.lastPcId = null;
    notifyListeners();
  }

  Future<void> clearPcs() async {
    _pcs = [];
    await storage.savePcs(_pcs);
    storage.lastPcId = null;
    notifyListeners();
  }

  /// Light tick for taps and clicks; [strong] for buttons that do something big.
  void haptic({bool strong = false}) {
    if (!_haptics) return;
    if (strong) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.selectionClick();
    }
  }
}
