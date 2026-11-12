import 'package:flutter/material.dart';

import '../services/connection_controller.dart';

/// The icon of an app on the PC, or a coloured letter tile while it is loading or when the PC has none.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.conn, required this.app, this.size = 40});

  final ConnectionController conn;

  /// App key, e.g. "chrome.exe".
  final String app;
  final double size;

  /// A steady colour per app so the same app always looks the same.
  static Color colorFor(String app) {
    var h = 0;
    for (final c in app.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.45, 0.42).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = conn.icons[app];
    if (bytes != null && bytes.isNotEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _letter(),
        ),
      );
    }
    return _letter();
  }

  Widget _letter() {
    final name = appDisplayName(app);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colorFor(app), borderRadius: BorderRadius.circular(size * 0.28)),
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.48),
      ),
    );
  }
}
