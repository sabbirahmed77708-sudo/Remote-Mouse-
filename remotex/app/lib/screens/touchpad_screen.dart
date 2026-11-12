import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/connection_controller.dart';
import '../widgets/common.dart';

/// Large touchpad with dedicated buttons.
///
/// Gestures: one finger moves, tap = left click, two-finger tap = right click,
/// two fingers drag = scroll, tap then touch-and-drag = drag and drop.
class TouchpadScreen extends StatefulWidget {
  const TouchpadScreen({super.key, required this.onConnect, this.onBack});

  final VoidCallback onConnect;
  final VoidCallback? onBack;

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
  final Set<String> _mods = {};

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

  // ---------- keys, shortcuts and apps (all through the existing connection API) ----------

  static const _modOrder = ['ctrl', 'alt', 'shift', 'win'];

  /// Sends [keys] together with any sticky modifiers that are switched on, then releases them.
  void _chord(List<String> keys) {
    final scope = AppScope.read(context);
    final mods = _modOrder.where(_mods.contains).where((m) => !keys.contains(m)).toList();
    scope.app.haptic();
    scope.conn.combo([...mods, ...keys]);
    if (_mods.isNotEmpty) setState(_mods.clear);
  }

  void _toggleMod(String m) {
    AppScope.read(context).app.haptic();
    setState(() => _mods.contains(m) ? _mods.remove(m) : _mods.add(m));
  }

  Future<void> _run(String command) async {
    final conn = AppScope.read(context).conn;
    AppScope.read(context).app.haptic();
    conn.combo(['win', 'r']);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    conn.typeText(command);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    conn.key('enter');
  }

  void _sheet(Widget Function(BuildContext) builder) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _Ui.panel,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: builder,
    );
  }

  void _openKeyboard() {
    final scope = AppScope.read(context);
    final ctrl = TextEditingController();
    _sheet((ctx) {
      void send() {
        final t = ctrl.text;
        if (t.isEmpty) return;
        scope.conn.typeText(t);
        ctrl.clear();
      }

      return Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => send(),
              decoration: InputDecoration(
                hintText: 'Type here and send to the PC',
                hintStyle: const TextStyle(color: _Ui.dim),
                filled: true,
                fillColor: _Ui.tile,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                suffixIcon: IconButton(onPressed: send, icon: const Icon(Icons.send_rounded, color: _Ui.accent)),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in const ['backspace', 'delete', 'space', 'left', 'up', 'down', 'right', 'home', 'end', 'pgup', 'pgdn'])
                  ActionChip(
                    backgroundColor: _Ui.tile,
                    side: BorderSide.none,
                    label: Text(k, style: const TextStyle(color: Colors.white)),
                    onPressed: () {
                      scope.app.haptic();
                      scope.conn.key(k);
                    },
                  ),
              ],
            ),
          ],
        ),
      );
    });
  }

  void _openFn() {
    _sheet((ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.1,
            children: [
              for (var i = 1; i <= 12; i++)
                PressableTile(
                  radius: 14,
                  color: _Ui.tile,
                  pressedColor: _Ui.accent,
                  onPress: () {
                    Navigator.pop(ctx);
                    _chord(['f$i']);
                  },
                  child: Text('F$i', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ));
  }

  void _openMore() {
    final scope = AppScope.read(context);
    Widget item(IconData icon, String label, VoidCallback f) => PressableTile(
          radius: 16,
          color: _Ui.tile,
          pressedColor: _Ui.accent,
          semanticLabel: label,
          onPress: f,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 24),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 12), textAlign: TextAlign.center),
            ],
          ),
        );
    _sheet((ctx) {
      void c(List<String> k) {
        scope.app.haptic();
        scope.conn.combo(k);
      }

      void m(String k) {
        scope.app.haptic();
        scope.conn.media(k);
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: GridView.count(
          shrinkWrap: true,
          crossAxisCount: 4,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.05,
          children: [
            item(Icons.copy_rounded, 'Copy', () => c(['ctrl', 'c'])),
            item(Icons.paste_rounded, 'Paste', () => c(['ctrl', 'v'])),
            item(Icons.undo_rounded, 'Undo', () => c(['ctrl', 'z'])),
            item(Icons.select_all_rounded, 'Select all', () => c(['ctrl', 'a'])),
            item(Icons.swap_horiz_rounded, 'Alt+Tab', () => c(['alt', 'tab'])),
            item(Icons.lock_rounded, 'Lock', () => c(['win', 'l'])),
            item(Icons.screenshot_monitor_rounded, 'Snip', () => c(['win', 'shift', 's'])),
            item(Icons.close_rounded, 'Close app', () => c(['alt', 'f4'])),
            item(Icons.volume_down_rounded, 'Vol -', () => m('voldown')),
            item(Icons.volume_up_rounded, 'Vol +', () => m('volup')),
            item(Icons.volume_off_rounded, 'Mute', () => m('mute')),
            item(Icons.play_arrow_rounded, 'Play/Pause', () => m('playpause')),
            item(Icons.skip_previous_rounded, 'Previous', () => m('prev')),
            item(Icons.skip_next_rounded, 'Next', () => m('next')),
            item(Icons.touch_app_rounded, 'Double click', () {
              scope.app.haptic(strong: true);
              scope.conn.click('left', count: 2);
            }),
          ],
        ),
      );
    });
  }

  // ---------- layout ----------

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final conn = scope.conn;
    return ColoredBox(
      color: _Ui.bg,
      child: ListenableBuilder(
        listenable: conn,
        builder: (context, _) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Column(
              children: [
                _topBar(conn),
                const SizedBox(height: 8),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: _buildPad(conn.connected)),
                      const SizedBox(width: 8),
                      _buildScrollStrip(),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 54,
                  child: Row(
                    children: [
                      Expanded(flex: 5, child: _mouseButton('left', 'Left')),
                      const SizedBox(width: 8),
                      Expanded(flex: 2, child: _mouseButton('middle', 'Mid', compact: true)),
                      const SizedBox(width: 8),
                      Expanded(flex: 5, child: _mouseButton('right', 'Right')),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _toolbar(),
                const SizedBox(height: 6),
                _modifierRow(),
                const SizedBox(height: 6),
                _dock(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _topBar(ConnectionController conn) {
    final style = LinkStyle.of(conn);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          ),
          const Icon(Icons.desktop_windows_rounded, color: _Ui.accent, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conn.connected ? (conn.pc?.name ?? 'PC') : 'No PC',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                Row(
                  children: [
                    Container(width: 7, height: 7, decoration: BoxDecoration(color: style.color, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        conn.connected
                            ? 'Connected${conn.latencyMs != null ? '  -  ${conn.latencyMs} ms' : ''}${conn.viaBluetooth ? '  -  Bluetooth' : ''}'
                            : style.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: style.color, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!conn.connected)
            TextButton(onPressed: widget.onConnect, child: const Text('Connect')),
        ],
      ),
    );
  }

  Widget _buildPad(bool connected) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        children: [
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF16324F), Color(0xFF0F1B2D), Color(0xFF0B1220)],
                ),
              ),
              child: SizedBox.expand(
                child: Stack(
                  children: [
                    const Center(
                      child: IgnorePointer(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.touch_app_rounded, size: 40, color: Colors.white24),
                            SizedBox(height: 8),
                            Text('Tap = click  -  two fingers = scroll', style: TextStyle(color: Colors.white30, fontSize: 12)),
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
                                  gradient: RadialGradient(colors: [_Ui.accent.withValues(alpha: 0.3), _Ui.accent.withValues(alpha: 0)]),
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
                color: _Ui.bg.withValues(alpha: 0.9),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off_rounded, size: 40, color: _Ui.dim),
                    const SizedBox(height: 12),
                    const Text('Not connected', style: TextStyle(color: Colors.white, fontSize: 16)),
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

  Widget _buildScrollStrip() {
    return SizedBox(
      width: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerMove: _stripMove,
          child: const ColoredBox(
            color: _Ui.panel,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Icon(Icons.keyboard_arrow_up_rounded, color: Colors.white70),
                Icon(Icons.unfold_more_rounded, color: _Ui.dim),
                Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mouseButton(String name, String label, {bool compact = false}) {
    final scope = AppScope.of(context);
    return PressableTile(
      immediate: true,
      radius: 16,
      color: compact ? _Ui.tile : _Ui.panel,
      pressedColor: _Ui.accent,
      semanticLabel: '$label click',
      onPress: () {
        scope.app.haptic(strong: !compact);
        scope.conn.button(name, true);
      },
      onRelease: () => scope.conn.button(name, false),
      child: compact
          ? const Icon(Icons.radio_button_checked_rounded, color: Colors.white70, size: 20)
          : Text(label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: PressableTile(
        radius: 14,
        color: _Ui.panel,
        pressedColor: _Ui.accent,
        semanticLabel: label,
        onPress: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    return SizedBox(
      height: 54,
      child: Row(
        children: [
          _tool(Icons.apps_rounded, 'Menu', () => _chord(['win'])),
          const SizedBox(width: 6),
          _tool(Icons.desktop_windows_rounded, 'Desktop', () => _chord(['win', 'd'])),
          const SizedBox(width: 6),
          _tool(Icons.public_rounded, 'Browser', () => _run('https://')),
          const SizedBox(width: 6),
          _tool(Icons.keyboard_rounded, 'Keyboard', _openKeyboard),
          const SizedBox(width: 6),
          _tool(Icons.more_horiz_rounded, 'More', _openMore),
        ],
      ),
    );
  }

  Widget _key(String label, {bool sticky = false, required VoidCallback onTap}) {
    final on = sticky && _mods.contains(label.toLowerCase());
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: PressableTile(
          radius: 10,
          color: on ? _Ui.accent : _Ui.tile,
          pressedColor: _Ui.accent,
          semanticLabel: label,
          onPress: onTap,
          child: Text(label, style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: on ? FontWeight.w800 : FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _modifierRow() {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          _key('Shift', sticky: true, onTap: () => _toggleMod('shift')),
          _key('Ctrl', sticky: true, onTap: () => _toggleMod('ctrl')),
          _key('Alt', sticky: true, onTap: () => _toggleMod('alt')),
          _key('Win', sticky: true, onTap: () => _toggleMod('win')),
          _key('Tab', onTap: () => _chord(['tab'])),
          _key('Enter', onTap: () => _chord(['enter'])),
          _key('Esc', onTap: () => _chord(['esc'])),
          _key('Fn', onTap: _openFn),
        ],
      ),
    );
  }

  Widget _dock() {
    Widget app(IconData icon, String label, Color color, VoidCallback f) => SizedBox(
          width: 62,
          child: PressableTile(
            radius: 14,
            color: _Ui.panel,
            pressedColor: _Ui.accent,
            semanticLabel: label,
            onPress: f,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 24),
                const SizedBox(height: 2),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 10)),
              ],
            ),
          ),
        );
    final items = <Widget>[
      app(Icons.public_rounded, 'Browser', const Color(0xFF4F8CFF), () => _run('https://')),
      app(Icons.folder_rounded, 'Files', const Color(0xFFF5C451), () => _chord(['win', 'e'])),
      app(Icons.edit_note_rounded, 'Notepad', const Color(0xFF8BD3FF), () => _run('notepad')),
      app(Icons.calculate_rounded, 'Calc', const Color(0xFF7BE0A4), () => _run('calc')),
      app(Icons.terminal_rounded, 'Terminal', Colors.white, () => _run('cmd')),
      app(Icons.monitor_heart_rounded, 'Tasks', const Color(0xFFFF8A65), () => _chord(['ctrl', 'shift', 'esc'])),
      app(Icons.settings_rounded, 'Settings', const Color(0xFFB0BEC5), () => _chord(['win', 'i'])),
      app(Icons.screenshot_monitor_rounded, 'Snip', const Color(0xFFCE93D8), () => _chord(['win', 'shift', 's'])),
      app(Icons.lock_rounded, 'Lock', const Color(0xFFEF9A9A), () => _chord(['win', 'l'])),
    ];
    return SizedBox(
      height: 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => items[i],
      ),
    );
  }
}

/// Colours for this screen: a dark, Windows-remote style look.
class _Ui {
  static const bg = Color(0xFF0B0F16);
  static const panel = Color(0xFF171D28);
  static const tile = Color(0xFF222B3A);
  static const accent = Color(0xFF2F7DF6);
  static const dim = Color(0xFF7C8699);
}
