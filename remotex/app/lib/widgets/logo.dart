import 'package:flutter/material.dart';

/// Remote Mouse mark: a computer mouse on a blue-violet tile. Same drawing as the launcher icon.
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
          colors: [Color(0xFF3B82F6), Color(0xFF6366F1)],
        ).createShader(tile),
    );
    final white = Paint()..color = Colors.white;
    final line = Paint()..color = const Color(0xFF4F74F4);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(38, 24, 32, 60), const Radius.circular(16)), white);
    canvas.drawRect(const Rect.fromLTWH(38, 50, 32, 2.2), line);
    canvas.drawRect(const Rect.fromLTWH(52.9, 24.5, 2.2, 26.5), line);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(51, 32, 6, 12), const Radius.circular(3)), line);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
