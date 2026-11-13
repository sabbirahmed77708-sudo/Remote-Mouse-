import 'package:flutter/services.dart';

/// Small helpers that live in the Android activity. Every call is safe on other platforms.
class NativeBridge {
  static const MethodChannel _channel = MethodChannel('remotex/bt');

  /// Asks for the camera permission. Returns granted, denied or unavailable.
  static Future<String> cameraPermission() async {
    try {
      return await _channel.invokeMethod<String>('camera') ?? 'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  static Future<void> appSettings() async {
    try {
      await _channel.invokeMethod<void>('appSettings');
    } catch (_) {}
  }

  /// Opens [url] in the phone's browser. False when that was not possible.
  static Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }
}
