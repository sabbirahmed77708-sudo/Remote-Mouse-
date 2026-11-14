import 'dart:async';

import 'package:flutter/material.dart';

import '../services/connection_controller.dart';

/// Colour + wording for each connection state.
class LinkStyle {
  const LinkStyle(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;

  static LinkStyle of(ConnectionController conn) {
    switch (conn.state) {
      case LinkState.connected:
        return LinkStyle('Connected to ${conn.pc?.name ?? 'PC'}', const Color(0xFF2EBD6B), Icons.link_rounded);
      case LinkState.connecting:
        return const LinkStyle('Connecting...', Color(0xFFF5A524), Icons.sync_rounded);
      case LinkState.reconnecting:
        return const LinkStyle('Reconnecting...', Color(0xFFF5A524), Icons.sync_problem_rounded);
      case LinkState.failed:
        return const LinkStyle('Connection failed', Color(0xFFE5484D), Icons.link_off_rounded);
      case LinkState.idle:
        return const LinkStyle('Not connected', Color(0xFF8B93A7), Icons.link_off_rounded);
    }
  }
}

/// Small animated "● Connected to PC" chip.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.conn, this.onTap});

  final ConnectionController conn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = LinkStyle.of(conn);
    final text = Theme.of(context).textTheme;
    return Material(
      color: style.color.withValues(alpha: 0.14),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: style.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    style.label,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelLarge?.copyWith(color: style.color, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded button that reacts to the finger immediately and can auto-repeat while held.
///
/// [immediate] uses raw pointer events (lowest latency, for screens that never scroll).
/// Otherwise a tap gesture is used so that scrolling a list does not press buttons.
class PressableTile extends StatefulWidget {
  const PressableTile({
    super.key,
    required this.child,
    required this.onPress,
    this.onRelease,
    this.repeat = false,
    this.immediate = false,
    this.color,
    this.pressedColor,
    this.radius = 20,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback onPress;
  final VoidCallback? onRelease;
  final bool repeat;
  final bool immediate;
  final Color? color;
  final Color? pressedColor;
  final double radius;
  final String? semanticLabel;

  @override
  State<PressableTile> createState() => _PressableTileState();
}

class _PressableTileState extends State<PressableTile> {
  bool _down = false;
  Timer? _delay;
  Timer? _timer;

  void _start() {
    if (_down) return;
    setState(() => _down = true);
    widget.onPress();
    if (widget.repeat) {
      _delay = Timer(const Duration(milliseconds: 350), () {
        _timer = Timer.periodic(const Duration(milliseconds: 90), (_) => widget.onPress());
      });
    }
  }

  void _stop() {
    _delay?.cancel();
    _timer?.cancel();
    _delay = null;
    _timer = null;
    if (!_down) return;
    if (mounted) setState(() => _down = false);
    widget.onRelease?.call();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = widget.color ?? cs.surfaceContainerHigh;
    final pressed = widget.pressedColor ?? cs.primaryContainer;
    final body = Semantics(
      button: true,
      label: widget.semanticLabel,
      child: AnimatedScale(
        scale: _down ? 0.95 : 1,
        duration: const Duration(milliseconds: 90),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          decoration: BoxDecoration(
            color: _down ? pressed : base,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          alignment: Alignment.center,
          child: widget.child,
        ),
      ),
    );
    if (widget.immediate) {
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _stop(),
        onPointerCancel: (_) => _stop(),
        child: body,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _start(),
      onTapUp: (_) => _stop(),
      onTapCancel: _stop,
      child: body,
    );
  }
}

/// Section title used on the dashboard and settings.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Row(
        children: [
          Container(width: 4, height: 16, decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

/// An icon on a soft rounded colour tile, used in lists and cards.
class IconChip extends StatelessWidget {
  const IconChip(this.icon, {super.key, this.color, this.size = 38});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(size * 0.32)),
      child: Icon(icon, color: c, size: size * 0.55),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    behavior: SnackBarBehavior.floating,
    backgroundColor: error ? Theme.of(context).colorScheme.errorContainer : null,
    duration: Duration(seconds: error ? 5 : 3),
  ));
}
