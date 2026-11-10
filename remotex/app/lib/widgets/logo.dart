import 'package:flutter/material.dart';

/// RemoteX mark: a rounded diamond with a pointer. Same shape as the launcher icon.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 108;
    canvas.save();
    canvas.scale(k);
    // diamond (a rounded square turned 45 degrees)
    canvas.save();
    canvas.translate(54, 54);
    canvas.rotate(0.7853981633974483);
    canvas.translate(-54, -54);
    final rect = RRect.fromRectAndRadius(const Rect.fromLTWH(26, 26, 56, 56), const Radius.circular(14));
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF4F8CFF), Color(0xFF965AFF)],
      ).createShader(const Rect.fromLTWH(26, 26, 56, 56));
    canvas.drawRRect(rect, paint);
    canvas.restore();
    // pointer
    final p = Path()
      ..moveTo(45, 41)
      ..lineTo(45, 67)
      ..lineTo(51, 61.5)
      ..lineTo(55, 70)
      ..lineTo(59, 68)
      ..lineTo(55, 59.5)
      ..lineTo(63, 59.5)
      ..close();
    canvas.drawPath(p, Paint()..color = Colors.white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
