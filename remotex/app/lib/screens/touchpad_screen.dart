import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../widgets/common.dart';

/// Large touchpad with dedicated buttons.
///
/// Gestures: one finger moves, tap = left click, two-finger tap = right click,
/// two fingers drag = scroll, tap then touch-and-drag = drag and drop.
class TouchpadScreen extends StatefulWidget {
  const TouchpadScreen({super.key, required this.onConnect});

  final VoidCallback onConnect;

  @override
  State<TouchpadScreen> createState() => _TouchpadScreenState();
}

class _TouchpadScreenState extends State<TouchpadScreen> {
  final Map<int, Offset> _pointers = {};
  final ValueNotifier<Offset?> _glow = ValueNotifier<Offset?>(null);

  DateTime _downAt = DateTime.now();
  DateTime _lastTapUp = DateTime.fromMillisecondsSinceEpoch(0);
  double _moved = 0;
  int _maxPointers = 0;
  bool _dragging = false;

  double _accX = 0, _accY = 0, _accSX = 0, _accSY = 0;
  Timer? _flushTimer;
  AppScope? _scope; // cached: a widget must not look up ancestors while being disposed

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = AppScope.of(context);
  }

  @override
  void initState() {
    super.initState();
    // ~125 updates per second: smooth, and many touch events collapse into one message
    _flushTimer = Timer.periodic(const Duration(milliseconds: 8), (_) => _flush());
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    if (_dragging) _scope?.conn.button('left', false);
    _glow.dispose();
    super.dispose();
  }

  void _flush() {
    final conn = _scope?.conn;
    if (conn == null) return;
    final ix = _accX.truncate(), iy = _accY.truncate();
    if (ix != 0 || iy != 0) {
      conn.move(ix, iy);
      _accX -= ix;
      _accY -= iy;
    }
    final sx = _accSX.truncate(), sy = _accSY.truncate();
    if (sx != 0 || sy != 0) {
      conn.scroll(sx, sy);
      _accSX -= sx;
      _accSY -= sy;
    }
  }

  void _down(PointerDownEvent e) {
    final scope = AppScope.read(context);
    _pointers[e.pointer] = e.localPosition;
    _glow.value = e.localPosition;
    final now = DateTime.now();
    if (_pointers.length == 1) {
      _downAt = now;
      _moved = 0;
      _maxPointers = 1;
      if (now.difference(_lastTapUp) < const Duration(milliseconds: 280) && !_dragging) {
        _dragging = true; // tap, then touch again and move = drag
        scope.conn.button('left', true);
        scope.app.haptic(strong: true);
      }
    } else {
      _maxPointers = max(_maxPointers, _pointers.length);
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    final app = AppScope.read(context).app;
    _pointers[e.pointer] = e.localPosition;
    _glow.value = e.localPosition;
    final d = e.delta;
    if (_pointers.length >= 2) {
      // each finger reports its own movement; the pair moves by the average
      final dd = d / 2;
      _moved += dd.distance;
      final k = 4.0 * app.scrollSpeed;
      final natural = app.naturalScroll;
      _accSY += (natural ? dd.dy : -dd.dy) * k;
      _accSX += (natural ? -dd.dx : dd.dx) * k;
    } else if (_maxPointers == 1) {
      _moved += d.distance;
      // gentle acceleration: fast swipes travel further
      final gain = app.pointerSpeed * (1 + min(d.distance, 30.0) / 30.0);
      _accX += d.dx * gain;
      _accY += d.dy * gain;
    }
  }

  void _up(PointerEvent e) {
    final scope = AppScope.read(context);
    _pointers.remove(e.pointer);
    if (_pointers.isNotEmpty) return;
    _glow.value = null;
    final now = DateTime.now();
    final short = now.difference(_downAt) < const Duration(milliseconds: 260);
    if (_dragging) {
      _dragging = false;
      scope.conn.button('left', false);
    } else if (_moved < 12 && short) {
      if (_maxPointers == 1) {
        scope.conn.click('left');
        scope.app.haptic();
        _lastTapUp = now;
      } else if (_maxPointers == 2) {
        scope.conn.click('right');
        scope.app.haptic();
      }
    }
    _maxPointers = 0;
  }

  void _stripMove(PointerMoveEvent e) {
    final app = AppScope.read(context).app;
    _accSY += (app.naturalScroll ? e.delta.dy : -e.delta.dy) * 4.0 * app.scrollSpeed;
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final conn = scope.conn;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: conn,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: StatusPill(conn: conn, onTap: widget.onConnect))),
                  if (conn.connected && conn.latencyMs != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text('${conn.latencyMs} ms', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.outline)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: _buildPad(cs, conn.connected)),
                    const SizedBox(width: 10),
                    _buildScrollStrip(cs),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 84,
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _mouseButton(context, 'left', 'Left', Icons.mouse_rounded),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 3,
                      child: _mouseButton(context, 'right', 'Right', Icons.mouse_outlined),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 52,
                child: Row(
                  children: [
                    Expanded(
                      child: PressableTile(
                        immediate: true,
                        radius: 16,
                        semanticLabel: 'Double click',
                        onPress: () {
                          scope.app.haptic(strong: true);
                          conn.click('left', count: 2);
                        },
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [Icon(Icons.ads_click_rounded, size: 20), SizedBox(width: 8), Text('Double click')],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _mouseButton(context, 'middle', 'Middle', Icons.radio_button_checked_rounded, compact: true),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPad(ColorScheme cs, bool connected) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: Stack(
        children: [
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.3),
                  radius: 1.2,
                  colors: [cs.primaryContainer.withValues(alpha: 0.55), cs.surfaceContainerHigh],
                ),
              ),
              child: SizedBox.expand(
                child: Stack(
                  children: [
                    Center(
                      child: IgnorePointer(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.touch_app_rounded, size: 44, color: cs.onSurfaceVariant.withValues(alpha: 0.35)),
                            const SizedBox(height: 10),
                            Text(
                              'Touchpad',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Tap to click  -  two fingers to scroll',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.45)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ValueListenableBuilder<Offset?>(
                      valueListenable: _glow,
                      builder: (context, o, _) {
                        return Positioned(
                          left: (o?.dx ?? 0) - 48,
                          top: (o?.dy ?? 0) - 48,
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 140),
                              opacity: o == null ? 0 : 1,
                              child: Container(
                                width: 96,
                                height: 96,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(colors: [cs.primary.withValues(alpha: 0.28), cs.primary.withValues(alpha: 0)]),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!connected)
            Positioned.fill(
              child: Container(
                color: cs.surface.withValues(alpha: 0.88),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_off_rounded, size: 40, color: cs.outline),
                    const SizedBox(height: 12),
                    Text('Not connected', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: widget.onConnect,
                      icon: const Icon(Icons.computer_rounded),
                      label: const Text('Connect to a PC'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScrollStrip(ColorScheme cs) {
    return SizedBox(
      width: 46,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerMove: _stripMove,
          child: ColoredBox(
            color: cs.surfaceContainerHigh,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Icon(Icons.keyboard_arrow_up_rounded, color: cs.onSurfaceVariant),
                Icon(Icons.unfold_more_rounded, color: cs.outline),
                Icon(Icons.keyboard_arrow_down_rounded, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mouseButton(BuildContext context, String name, String label, IconData icon, {bool compact = false}) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return PressableTile(
      immediate: true,
      radius: compact ? 16 : 24,
      color: compact ? null : cs.secondaryContainer,
      pressedColor: cs.primary,
      semanticLabel: '$label click',
      onPress: () {
        scope.app.haptic(strong: !compact);
        scope.conn.button(name, true);
      },
      onRelease: () => scope.conn.button(name, false),
      child: compact
          ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 20), const SizedBox(width: 8), Text(label)])
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 26, color: cs.onSecondaryContainer),
                const SizedBox(height: 4),
                Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSecondaryContainer)),
              ],
            ),
    );
  }
}
