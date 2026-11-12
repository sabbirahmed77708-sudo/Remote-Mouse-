import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Remote Mouse mark: a tilted computer mouse with wireless waves on a green tile.
/// Same drawing as the launcher icon.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 108);
    const tile = Rect.fromLTWH(0, 0, 108, 108);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tile, const Radius.circular(26)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF10B981), Color(0xFF065F46)],
        ).createShader(tile),
    );
    // mouse, tilted 18 degrees clockwise
    canvas.save();
    canvas.translate(54, 54);
    canvas.rotate(18 * math.pi / 180);
    canvas.translate(-54, -54);
    final line = Paint()..color = const Color(0xFF10966E);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(38, 34, 32, 56), const Radius.circular(16)), Paint()..color = Colors.white);
    canvas.drawRect(const Rect.fromLTWH(38, 57.5, 32, 2.2), line);
    canvas.drawRect(const Rect.fromLTWH(52.9, 34, 2.2, 23.5), line);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(51, 42, 6, 12), const Radius.circular(3)), line);
    canvas.restore();
    // wireless waves
    const alphas = [255, 195, 135];
    const radii = [10.0, 18.0, 26.0];
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: const Offset(72, 28), radius: radii[i]),
        -80 * math.pi / 180,
        90 * math.pi / 180,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.white.withAlpha(alphas[i]),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
