import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// Pure HID encoding (unit tested). Report layouts match the descriptor in
// android/.../MainActivity.kt: id 1 = mouse, id 2 = keyboard, id 3 = consumer control.
// ---------------------------------------------------------------------------

const int kHidMouse = 1;
const int kHidKeyboard = 2;
const int kHidConsumer = 3;

const int modCtrl = 0x01, modShift = 0x02, modAlt = 0x04, modWin = 0x08;

const Map<String, int> _modifierBits = {'ctrl': modCtrl, 'shift': modShift, 'alt': modAlt, 'win': modWin};

final Map<String, int> _keyUsage = _buildKeyUsage();

Map<String, int> _buildKeyUsage() {
  final m = <String, int>{
    'enter': 0x28,
    'esc': 0x29,
    'backspace': 0x2A,
    'tab': 0x2B,
    'space': 0x2C,
    'insert': 0x49,
    'home': 0x4A,
    'pgup': 0x4B,
    'delete': 0x4C,
    'end': 0x4D,
    'pgdn': 0x4E,
    'right': 0x4F,
    'left': 0x50,
    'down': 0x51,
    'up': 0x52,
  };
  for (var i = 0; i < 26; i++) {
    m[String.fromCharCode(0x61 + i)] = 0x04 + i;
  }
  for (var i = 1; i <= 9; i++) {
    m['$i'] = 0x1D + i;
  }
  m['0'] = 0x27;
  for (var i = 1; i <= 12; i++) {
    m['f$i'] = 0x39 + i;
  }
  return m;
}

/// HID usage for a key name used by the app ("enter", "f5", "a", ...), or null.
int? hidKeyUsage(String name) => _keyUsage[name.toLowerCase()];

/// Modifier bit for "ctrl", "shift", "alt" or "win", or 0.
int hidModifierBit(String name) => _modifierBits[name.toLowerCase()] ?? 0;

const Map<String, int> _consumerUsage = {
  'playpause': 0xCD,
  'next': 0xB5,
  'prev': 0xB6,
  'stop': 0xB7,
  'mute': 0xE2,
  'volup': 0xE9,
  'voldown': 0xEA,
};

int? hidConsumerUsage(String name) => _consumerUsage[name];

int _s8(int v) => v.clamp(-127, 127);

/// buttons: bit0 left, bit1 right, bit2 middle.
Uint8List mouseReport(int buttons, int dx, int dy, {int wheel = 0, int pan = 0}) =>
    Uint8List.fromList([buttons & 7, _s8(dx) & 0xFF, _s8(dy) & 0xFF, _s8(wheel) & 0xFF, _s8(pan) & 0xFF]);

Uint8List keyboardReport(int modifiers, List<int> usages) {
  final k = usages.take(6).toList();
  while (k.length < 6) {
    k.add(0);
  }
  return Uint8List.fromList([modifiers & 0xFF, 0, ...k]);
}

Uint8List consumerReport(int usage) => Uint8List.fromList([usage & 0xFF, (usage >> 8) & 0xFF]);

/// US-layout (modifier, usage) for one typed character, or null if it cannot be typed.
(int, int)? hidForChar(String ch) {
  if (ch.length != 1) return null;
  final c = ch.codeUnitAt(0);
  if (c >= 0x61 && c <= 0x7A) return (0, 0x04 + c - 0x61);
  if (c >= 0x41 && c <= 0x5A) return (modShift, 0x04 + c - 0x41);
  if (c >= 0x31 && c <= 0x39) return (0, 0x1E + c - 0x31);
  if (c == 0x30) return (0, 0x27);
  const shiftedDigits = ')!@#\$%^&*(';
  final si = shiftedDigits.indexOf(ch);
  if (si >= 0) return (modShift, si == 0 ? 0x27 : 0x1E + si - 1);
  const plain = {
    ' ': 0x2C, '\n': 0x28, '\t': 0x2B, '-': 0x2D, '=': 0x2E, '[': 0x2F, ']': 0x30, '\\': 0x31,
    ';': 0x33, "'": 0x34, '`': 0x35, ',': 0x36, '.': 0x37, '/': 0x38,
  };
  const shifted = {
    '_': 0x2D, '+': 0x2E, '{': 0x2F, '}': 0x30, '|': 0x31, ':': 0x33, '"': 0x34, '~': 0x35,
    '<': 0x36, '>': 0x37, '?': 0x38,
  };
  if (plain.containsKey(ch)) return (0, plain[ch]!);
  if (shifted.containsKey(ch)) return (modShift, shifted[ch]!);
  return null;
}

// ---------------------------------------------------------------------------
// Bluetooth HID device (the phone pretends to be a Bluetooth mouse + keyboard)
// ---------------------------------------------------------------------------

/// Talks to the native side (MainActivity.kt). Needs Android 9+ and Bluetooth.
class BluetoothHid extends ChangeNotifier {
  BluetoothHid() {
    _channel.setMethodCallHandler(_onNative);
  }

  static const MethodChannel _channel = MethodChannel('remotex/bt');

  bool initialized = false;
  bool supported = false;
  bool ready = false; // registered as HID device with Android
  String? problem;
  String? connectedName;
  String? connectedAddress;
  List<({String name, String address})> bonded = const [];

  int _buttons = 0;
  double _accWheel = 0, _accPan = 0;

  bool get connected => connectedAddress != null;

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method == 'state') {
      final a = Map<String, dynamic>.from(call.arguments as Map);
      ready = a['registered'] == true;
      final state = a['state'];
      if (state == 'connected') {
        connectedName = a['name'] as String?;
        connectedAddress = a['address'] as String?;
      } else if (state == 'disconnected') {
        connectedName = null;
        connectedAddress = null;
        _buttons = 0;
      }
      notifyListeners();
    }
    return null;
  }

  Future<bool> init() async {
    try {
      final r = Map<String, dynamic>.from(await _channel.invokeMethod('init') as Map);
      supported = r['supported'] == true;
      problem = r['problem'] as String?;
      ready = r['registered'] == true;
    } on MissingPluginException {
      supported = false;
      problem = 'Bluetooth control is only available on Android.';
    } on PlatformException catch (e) {
      supported = false;
      problem = e.message ?? 'Bluetooth could not be started.';
    }
    initialized = true;
    if (supported) await refreshDevices();
    notifyListeners();
    return supported;
  }

  Future<void> refreshDevices() async {
    try {
      final list = await _channel.invokeMethod('bonded') as List<dynamic>;
      bonded = [
        for (final e in list)
          (name: (e as Map)['name'] as String? ?? 'Unknown device', address: e['address'] as String),
      ];
    } catch (_) {
      bonded = const [];
    }
    notifyListeners();
  }

  Future<void> makeDiscoverable() async {
    try {
      await _channel.invokeMethod('discoverable');
    } catch (_) {}
  }

  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod('settings');
    } catch (_) {}
  }

  Future<bool> connect(String address) async {
    try {
      return await _channel.invokeMethod('connect', {'address': address}) == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (_) {}
    connectedName = null;
    connectedAddress = null;
    _buttons = 0;
    notifyListeners();
  }

  void _report(int id, Uint8List data) {
    if (!connected) return;
    unawaited(_channel.invokeMethod('send', {'id': id, 'data': data}).catchError((_) => null));
  }

  void _sendMouse({int dx = 0, int dy = 0, int wheel = 0, int pan = 0}) {
    // one report carries at most +-127 per axis
    var x = dx, y = dy;
    do {
      final sx = x.clamp(-127, 127), sy = y.clamp(-127, 127);
      _report(kHidMouse, mouseReport(_buttons, sx, sy, wheel: wheel, pan: pan));
      x -= sx;
      y -= sy;
      wheel = 0;
      pan = 0;
    } while (x != 0 || y != 0);
  }

  static int _buttonBit(Object? name) => name == 'left' ? 1 : (name == 'right' ? 2 : (name == 'middle' ? 4 : 0));

  void _pressKeys(int mods, List<int> usages) {
    _report(kHidKeyboard, keyboardReport(mods, usages));
    _report(kHidKeyboard, keyboardReport(0, const []));
  }

  /// Takes the same messages the Wi-Fi protocol uses, so the screens do not care which link is active.
  void handle(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'move':
        _sendMouse(dx: (m['dx'] as num).toInt(), dy: (m['dy'] as num).toInt());
      case 'btn':
        final bit = _buttonBit(m['b']);
        if (bit == 0) return;
        _buttons = m['d'] == true ? (_buttons | bit) : (_buttons & ~bit);
        _sendMouse();
      case 'click':
        final bit = _buttonBit(m['b']);
        if (bit == 0) return;
        final n = m['n'] == 2 ? 2 : 1;
        unawaited(() async {
          for (var i = 0; i < n; i++) {
            _buttons |= bit;
            _sendMouse();
            await Future<void>.delayed(const Duration(milliseconds: 25));
            _buttons &= ~bit;
            _sendMouse();
            if (i + 1 < n) await Future<void>.delayed(const Duration(milliseconds: 45));
          }
        }());
      case 'scroll':
        // the app uses 120 per wheel notch; HID wheel reports whole notches, so keep the remainder
        _accWheel += (m['dy'] as num).toDouble() / 40;
        _accPan += (m['dx'] as num).toDouble() / 40;
        final w = _accWheel.truncate(), p = _accPan.truncate();
        if (w != 0 || p != 0) {
          _accWheel -= w;
          _accPan -= p;
          _sendMouse(wheel: w, pan: p);
        }
      case 'text':
        final s = m['s'];
        if (s is! String) return;
        unawaited(() async {
          var count = 0;
          for (final ch in s.split('')) {
            final k = hidForChar(ch);
            if (k == null) continue;
            _pressKeys(k.$1, [k.$2]);
            if (++count % 8 == 0) await Future<void>.delayed(const Duration(milliseconds: 8));
          }
        }());
      case 'key':
        final u = m['k'] is String ? hidKeyUsage(m['k'] as String) : null;
        if (u == null) return;
        final n = ((m['n'] as num?)?.toInt() ?? 1).clamp(1, 50);
        for (var i = 0; i < n; i++) {
          _pressKeys(0, [u]);
        }
      case 'combo':
        final keys = m['k'];
        if (keys is! List) return;
        var mods = 0;
        final usages = <int>[];
        for (final k in keys) {
          if (k is! String) return;
          final bit = hidModifierBit(k);
          if (bit != 0) {
            mods |= bit;
          } else {
            final u = hidKeyUsage(k);
            if (u == null) return;
            usages.add(u);
          }
        }
        _pressKeys(mods, usages);
      case 'media':
        final u = m['k'] is String ? hidConsumerUsage(m['k'] as String) : null;
        if (u == null) return;
        _report(kHidConsumer, consumerReport(u));
        _report(kHidConsumer, consumerReport(0));
    }
  }
}
