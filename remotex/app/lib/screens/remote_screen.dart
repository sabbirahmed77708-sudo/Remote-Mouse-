import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../models/running_app.dart';
import '../services/connection_controller.dart';
import '../widgets/common.dart';

/// The remote control: live PC screen as a touchpad, with panels that slide up from the bottom
/// (keyboard, media, Fn keys, shortcuts, apps, power). The touchpad stays on screen and just gets smaller.
///
/// Gestures: one finger moves, tap = left click, two-finger tap = right click,
/// two fingers drag = scroll, tap then touch-and-drag = drag and drop.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({
    super.key,
    required this.onConnect,
    required this.onBack,
    this.active = true,
    this.initialPanel = RemotePanel.none,
  });

  final VoidCallback onConnect;
  final VoidCallback onBack;

  /// False while another page covers this one: the live preview is switched off to save data and battery.
  final bool active;
  final RemotePanel initialPanel;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

enum RemotePanel { none, keyboard, media, fn, ctrl, apps, power }

class _RemoteScreenState extends State<RemoteScreen> {
  final Map<int, Offset> _pointers = {};
  final ValueNotifier<Offset?> _glow = ValueNotifier<Offset?>(null);

  DateTime _downAt = DateTime.now();
  DateTime _lastTapUp = DateTime.fromMillisecondsSinceEpoch(0);
  double _moved = 0;
  int _maxPointers = 0;
  bool _dragging = false;
  final Set<String> _mods = {};
  bool _fill = true; // desktop picture fills the whole pad (cropped) or fits inside it
  bool _preview = true; // user switch for the live PC screen

  double _accX = 0, _accY = 0, _accSX = 0, _accSY = 0;
  Timer? _flushTimer;
  AppScope? _scope; // cached: a widget must not look up ancestors while being disposed

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final first = _scope == null;
    _scope = AppScope.of(context);
    if (first) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncPreview();
        _scope?.conn.refreshApps();
        if (_panel == RemotePanel.keyboard && mounted) _kbFocus.requestFocus();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    // ~125 updates per second: smooth, and many touch events collapse into one message
    _flushTimer = Timer.periodic(const Duration(milliseconds: 8), (_) => _flush());
    // the list of windows open on the PC: quickly while the Apps panel is open, now and then otherwise
    _appsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _tick++;
      final c = _scope?.conn;
      if (c == null || !c.connected || !widget.active) return;
      if (_panel == RemotePanel.apps || _tick % 3 == 0) c.refreshApps();
    });
  }

  void _syncPreview() {
    final conn = _scope?.conn;
    if (conn == null) return;
    conn.watchScreen(widget.active && _preview, width: 960);
  }

  @override
  void didUpdateWidget(covariant RemoteScreen old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _syncPreview();
  }

  @override
  void dispose() {
    _scope?.conn.watchScreen(false);
    _flushTimer?.cancel();
    _appsTimer?.cancel();
    _kbFocus.dispose();
    if (_dragging) _scope?.conn.button('left', false);
    _glow.dispose();
    _text.dispose();
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

  // ---------- state ----------

  late RemotePanel _panel = widget.initialPanel;
  Timer? _appsTimer;
  int _tick = 0;
  final FocusNode _kbFocus = FocusNode();
  // The hidden typing field always holds these invisible characters, so that a Backspace on the
  // phone keyboard is seen as a deletion even when nothing has been typed yet.
  static final String _base = '\u200b' * 8;

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
    conn.combo(['win', 'r']);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    conn.typeText(command);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    conn.key('enter');
  }

  void _launch(_App a) {
    AppScope.read(context).app.haptic();
    if (a.keys != null) {
      _chord(a.keys!);
    } else {
      unawaited(_run(a.command!));
    }
    // the new window needs a moment to appear in the list
    for (final ms in const [1200, 3000]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (mounted) _scope?.conn.refreshApps();
      });
    }
  }

  void _setPanel(RemotePanel p) {
    AppScope.read(context).app.haptic();
    setState(() => _panel = _panel == p ? RemotePanel.none : p);
    if (_panel == RemotePanel.keyboard) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _kbFocus.requestFocus();
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      });
    } else {
      _kbFocus.unfocus();
    }
    if (_panel == RemotePanel.apps) AppScope.read(context).conn.refreshApps();
  }

  Future<void> _confirmPower(String title, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: const Text('This will happen on your PC right now.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(title)),
        ],
      ),
    );
    if (ok == true && mounted) {
      AppScope.read(context).app.haptic(strong: true);
      AppScope.read(context).conn.power(action);
    }
  }

  // ---------- layout ----------

  @override
  Widget build(BuildContext context) {
    final conn = AppScope.of(context).conn;
    return ColoredBox(
      color: _Ui.bg,
      child: ListenableBuilder(
        listenable: conn,
        builder: (context, _) {
          return Column(
            children: [
              // Full-bleed desktop view with the top bar and scroll strip floating over it
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _buildPad(conn.connected)),
                    Positioned(top: 0, left: 0, right: 0, child: _topBar(conn)),
                    Positioned(right: 8, top: 72, bottom: 12, child: _buildScrollStrip()),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: SizedBox(
                  height: 48,
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
              ),
              // The panel slides up from the bottom; the pad above simply gets smaller.
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: _panel == RemotePanel.none
                    ? const SizedBox(width: double.infinity)
                    : Container(
                        width: double.infinity,
                        height: _panelHeight(_panel),
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
                        decoration: const BoxDecoration(
                          color: _Ui.panel,
                          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                        ),
                        child: _panelBody(_panel),
                      ),
              ),
              _tabBar(),
            ],
          );
        },
      ),
    );
  }

  double _panelHeight(RemotePanel p) {
    switch (p) {
      case RemotePanel.keyboard:
        return 168;
      case RemotePanel.media:
        return 92;
      case RemotePanel.fn:
        return 118;
      case RemotePanel.ctrl:
        return 190;
      case RemotePanel.apps:
        return 172;
      case RemotePanel.power:
        return 100;
      case RemotePanel.none:
        return 0;
    }
  }

  Widget _topBar(ConnectionController conn) {
    final style = LinkStyle.of(conn);
    RunningApp? current;
    for (final a in conn.apps.value) {
      if (a.foreground) current = a;
    }
    return Container(
      height: 64,
      padding: const EdgeInsets.only(top: 4, right: 2),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
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
          if (current != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _PcIcon(app: current, icons: conn.appIcons, size: 30),
            ),
          if (conn.connected && !conn.viaBluetooth) ...[
            IconButton(
              tooltip: _fill ? 'Show whole screen' : 'Fill the pad',
              onPressed: () => setState(() => _fill = !_fill),
              icon: Icon(_fill ? Icons.fit_screen_rounded : Icons.fullscreen_rounded, color: Colors.white70),
            ),
            IconButton(
              tooltip: _preview ? 'Hide PC screen' : 'Show PC screen',
              onPressed: () {
                setState(() => _preview = !_preview);
                _syncPreview();
              },
              icon: Icon(_preview ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                  color: _preview ? _Ui.accent : _Ui.dim),
            ),
          ],
          if (!conn.connected) TextButton(onPressed: widget.onConnect, child: const Text('Connect')),
        ],
      ),
    );
  }

  Widget _buildPad(bool connected) {
    return ClipRRect(
      borderRadius: BorderRadius.zero,
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
                    ValueListenableBuilder<Uint8List?>(
                      valueListenable: _scope!.conn.screenFrame,
                      builder: (context, frame, _) {
                        if (frame != null) {
                          return Positioned.fill(
                            child: IgnorePointer(
                              child: Image.memory(frame, fit: _fill ? BoxFit.cover : BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.low),
                            ),
                          );
                        }
                        return const Center(
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
                        );
                      },
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
      width: 38,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerMove: _stripMove,
          child: const ColoredBox(
            color: Color(0x8C171D28),
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

  // ---------- bottom tabs ----------

  Widget _tabBar() {
    Widget tab(RemotePanel p, IconData icon, String label) {
      final on = _panel == p;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          label: label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setPanel(p),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 44,
                  height: 28,
                  decoration: BoxDecoration(
                    color: on ? _Ui.accent.withValues(alpha: 0.28) : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, size: 22, color: on ? Colors.white : _Ui.dim),
                ),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(fontSize: 10.5, color: on ? Colors.white : _Ui.dim, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      height: 58,
      decoration: const BoxDecoration(color: Color(0xFF10151E)),
      child: Row(
        children: [
          tab(RemotePanel.none, Icons.touch_app_rounded, 'Pad'),
          tab(RemotePanel.keyboard, Icons.keyboard_rounded, 'Keys'),
          tab(RemotePanel.media, Icons.play_circle_rounded, 'Media'),
          tab(RemotePanel.fn, Icons.functions_rounded, 'Fn'),
          tab(RemotePanel.ctrl, Icons.bolt_rounded, 'Ctrl'),
          tab(RemotePanel.apps, Icons.apps_rounded, 'Apps'),
          tab(RemotePanel.power, Icons.power_settings_new_rounded, 'Power'),
        ],
      ),
    );
  }

  // ---------- panels ----------

  late final TextEditingController _text = TextEditingController.fromValue(
    TextEditingValue(text: _base, selection: TextSelection.collapsed(offset: _base.length)),
  );

  Widget _panelBody(RemotePanel p) {
    switch (p) {
      case RemotePanel.keyboard:
        return _keyboardPanel();
      case RemotePanel.media:
        return _mediaPanel();
      case RemotePanel.fn:
        return _fnPanel();
      case RemotePanel.ctrl:
        return _ctrlPanel();
      case RemotePanel.apps:
        return _appsPanel();
      case RemotePanel.power:
        return _powerPanel();
      case RemotePanel.none:
        return const SizedBox.shrink();
    }
  }

  /// A key button in a row. Sticky ones stay lit until the next key is sent.
  Widget _k(String label, {required VoidCallback onTap, bool sticky = false, IconData? icon, bool repeat = false}) {
    final on = sticky && _mods.contains(label.toLowerCase());
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: PressableTile(
          radius: 10,
          repeat: repeat,
          color: on ? _Ui.accent : _Ui.tile,
          pressedColor: _Ui.accent,
          semanticLabel: label,
          onPress: onTap,
          child: icon != null
              ? Icon(icon, size: 18, color: Colors.white)
              : Text(label, style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: on ? FontWeight.w800 : FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _modRow() {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          _k('Shift', sticky: true, onTap: () => _toggleMod('shift')),
          _k('Ctrl', sticky: true, onTap: () => _toggleMod('ctrl')),
          _k('Win', sticky: true, icon: Icons.window_rounded, onTap: () => _toggleMod('win')),
          _k('Alt', sticky: true, onTap: () => _toggleMod('alt')),
        ],
      ),
    );
  }

  Widget _repeatKey(String label, String name, {IconData? icon}) {
    final conn = AppScope.read(context).conn;
    return _k(label, icon: icon, repeat: true, onTap: () {
      AppScope.read(context).app.haptic();
      conn.key(name);
    });
  }

  /// Whatever the phone keyboard does goes straight to the PC: typed characters are typed there,
  /// Backspace deletes there, Enter presses Enter. No Send button.
  void _liveText(String v) {
    final conn = AppScope.read(context).conn;
    var p = 0;
    final m = min(_base.length, v.length);
    while (p < m && _base.codeUnitAt(p) == v.codeUnitAt(p)) {
      p++;
    }
    final deleted = _base.length - p;
    final added = v.substring(p);
    // put the invisible padding back right away, so the next key is seen the same way
    _text.value = TextEditingValue(text: _base, selection: TextSelection.collapsed(offset: _base.length));
    if (deleted > 0) conn.key('backspace', count: deleted);
    if (added.isEmpty) return;
    if (_mods.isNotEmpty && added.runes.length == 1) {
      _chord([added.toLowerCase()]); // e.g. Ctrl switched on, then C on the phone keyboard = Ctrl+C
      return;
    }
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isNotEmpty) conn.typeText(buffer.toString());
      buffer.clear();
    }

    for (final ch in added.characters) {
      if (ch == '\n' || ch == '\r\n' || ch == '\r') {
        flush();
        conn.key('enter');
      } else if (ch != '\u200b') {
        buffer.write(ch);
      }
    }
    flush();
  }

  Widget _keyboardPanel() {
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _kbFocus.requestFocus();
                    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(color: _Ui.tile, borderRadius: BorderRadius.circular(14)),
                    child: Row(
                      children: [
                        const Icon(Icons.keyboard_alt_rounded, color: _Ui.accent, size: 20),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('Type on your phone keyboard, it types on the PC',
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white70, fontSize: 13)),
                        ),
                        // the real input field: one pixel, invisible, but it receives the phone keyboard
                        SizedBox(
                          width: 1,
                          height: 1,
                          child: TextField(
                            controller: _text,
                            focusNode: _kbFocus,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableInteractiveSelection: false,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            maxLines: null,
                            style: const TextStyle(color: Colors.transparent, fontSize: 1),
                            cursorColor: Colors.transparent,
                            decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
                            onChanged: _liveText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 38,
          child: Row(
            children: [
              _k('Shift', sticky: true, onTap: () => _toggleMod('shift')),
              _k('Ctrl', sticky: true, onTap: () => _toggleMod('ctrl')),
              _k('Win', sticky: true, icon: Icons.window_rounded, onTap: () => _toggleMod('win')),
              _k('Alt', sticky: true, onTap: () => _toggleMod('alt')),
              _k('Tab', onTap: () => _chord(['tab'])),
              _k('Esc', onTap: () => _chord(['esc'])),
              _repeatKey('Bksp', 'backspace', icon: Icons.backspace_outlined),
              _k('Enter', onTap: () => _chord(['enter'])),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 38,
          child: Row(
            children: [
              _repeatKey('Left', 'left', icon: Icons.keyboard_arrow_left_rounded),
              _repeatKey('Up', 'up', icon: Icons.keyboard_arrow_up_rounded),
              _repeatKey('Down', 'down', icon: Icons.keyboard_arrow_down_rounded),
              _repeatKey('Right', 'right', icon: Icons.keyboard_arrow_right_rounded),
              _repeatKey('Del', 'delete'),
              _repeatKey('Home', 'home'),
              _repeatKey('End', 'end'),
              _repeatKey('Space', 'space', icon: Icons.space_bar_rounded),
            ],
          ),
        ),
      ],
    );
  }

  /// Big icon button with a tiny label (media and power panels).
  Widget _big(IconData icon, String label, VoidCallback onTap, {Color color = Colors.white, bool repeat = false}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: PressableTile(
          radius: 16,
          repeat: repeat,
          color: _Ui.tile,
          pressedColor: _Ui.accent,
          semanticLabel: label,
          onPress: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 3),
              Text(label, maxLines: 1, style: const TextStyle(color: Colors.white70, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mediaPanel() {
    final conn = AppScope.read(context).conn;
    void m(String k) {
      AppScope.read(context).app.haptic();
      conn.media(k);
    }

    return Row(
      children: [
        _big(Icons.skip_previous_rounded, 'Prev', () => m('prev')),
        _big(Icons.play_circle_rounded, 'Play', () => m('playpause'), color: _Ui.accent),
        _big(Icons.skip_next_rounded, 'Next', () => m('next')),
        _big(Icons.volume_down_rounded, 'Vol -', () => m('voldown'), repeat: true),
        _big(Icons.volume_up_rounded, 'Vol +', () => m('volup'), repeat: true),
        _big(Icons.volume_off_rounded, 'Mute', () => m('mute')),
      ],
    );
  }

  Widget _fnPanel() {
    Widget row(int from) => SizedBox(
          height: 38,
          child: Row(children: [for (var i = from; i < from + 6; i++) _k('F$i', onTap: () => _chord(['f$i']))]),
        );
    return Column(children: [row(1), const SizedBox(height: 8), row(7)]);
  }

  Future<void> _pastePhone() async {
    final conn = AppScope.read(context).conn;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final t = data?.text;
    if (t == null || t.isEmpty) {
      showSnack(context, 'The phone clipboard is empty');
      return;
    }
    AppScope.read(context).app.haptic();
    conn.typeText(t);
  }

  Widget _ctrlPanel() {
    Widget chip(IconData icon, String label, VoidCallback onTap) => SizedBox(
          width: 94,
          height: 36,
          child: PressableTile(
            radius: 12,
            color: _Ui.tile,
            pressedColor: _Ui.accent,
            semanticLabel: label,
            onPress: onTap,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: Colors.white),
                const SizedBox(width: 5),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        );
    return Column(
      children: [
        _modRow(),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                chip(Icons.copy_rounded, 'Copy', () => _chord(['ctrl', 'c'])),
                chip(Icons.paste_rounded, 'Paste', () => _chord(['ctrl', 'v'])),
                chip(Icons.content_cut_rounded, 'Cut', () => _chord(['ctrl', 'x'])),
                chip(Icons.undo_rounded, 'Undo', () => _chord(['ctrl', 'z'])),
                chip(Icons.redo_rounded, 'Redo', () => _chord(['ctrl', 'y'])),
                chip(Icons.select_all_rounded, 'All', () => _chord(['ctrl', 'a'])),
                chip(Icons.save_rounded, 'Save', () => _chord(['ctrl', 's'])),
                chip(Icons.search_rounded, 'Find', () => _chord(['ctrl', 'f'])),
                chip(Icons.swap_horiz_rounded, 'Alt+Tab', () => _chord(['alt', 'tab'])),
                chip(Icons.view_agenda_rounded, 'Tasks', () => _chord(['win', 'tab'])),
                chip(Icons.desktop_windows_rounded, 'Desktop', () => _chord(['win', 'd'])),
                chip(Icons.window_rounded, 'Start', () => _chord(['win'])),
                chip(Icons.screenshot_monitor_rounded, 'Snip', () => _chord(['win', 'shift', 's'])),
                chip(Icons.close_rounded, 'Close', () => _chord(['alt', 'f4'])),
                chip(Icons.content_paste_go_rounded, 'Phone clip', _pastePhone),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _appTile(_App a) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _launch(a),
      child: SizedBox(
        width: 62,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _AppIcon(app: a),
            const SizedBox(height: 3),
            Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  /// A window that is open on the PC: its real icon, tap to bring it to the front, x to close it.
  Widget _openTile(ConnectionController conn, RunningApp a) {
    return SizedBox(
      width: 66,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                AppScope.read(context).app.haptic();
                conn.focusApp(a.id);
                Future<void>.delayed(const Duration(milliseconds: 700), conn.refreshApps);
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: a.foreground ? _Ui.accent : Colors.transparent, width: 2),
                    ),
                    child: _PcIcon(app: a, icons: conn.appIcons, size: 38),
                  ),
                  const SizedBox(height: 3),
                  Text(a.title.isEmpty ? a.exe : a.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 10)),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 2,
            child: GestureDetector(
              onTap: () {
                AppScope.read(context).app.haptic(strong: true);
                conn.closeApp(a.id);
                Future<void>.delayed(const Duration(milliseconds: 800), conn.refreshApps);
              },
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(color: Color(0xFFE5484D), shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _appsPanel() {
    final conn = AppScope.read(context).conn;
    return Column(
      children: [
        SizedBox(
          height: 70,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _apps.length,
            itemBuilder: (_, i) => _appTile(_apps[i]),
          ),
        ),
        const Divider(height: 10, color: Color(0x22FFFFFF)),
        SizedBox(
          height: 70,
          child: ValueListenableBuilder<List<RunningApp>>(
            valueListenable: conn.apps,
            builder: (context, list, _) {
              if (list.isEmpty) {
                return Center(
                  child: Text(conn.viaBluetooth ? 'Open apps are not available over Bluetooth' : 'Nothing open on the PC',
                      style: const TextStyle(color: _Ui.dim, fontSize: 12)),
                );
              }
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: list.length,
                itemBuilder: (_, i) => _openTile(conn, list[i]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _powerPanel() {
    final conn = AppScope.read(context).conn;
    return Row(
      children: [
        _big(Icons.lock_rounded, 'Lock', () {
          AppScope.read(context).app.haptic();
          conn.power('lock');
        }),
        _big(Icons.bedtime_rounded, 'Sleep', () => _confirmPower('Sleep', 'sleep'), color: const Color(0xFF8BD3FF)),
        _big(Icons.logout_rounded, 'Sign out', () => _confirmPower('Sign out', 'signout'), color: const Color(0xFFF5C451)),
        _big(Icons.restart_alt_rounded, 'Restart', () => _confirmPower('Restart', 'restart'), color: const Color(0xFFFF8A65)),
        _big(Icons.power_settings_new_rounded, 'Shut down', () => _confirmPower('Shut down', 'shutdown'), color: const Color(0xFFFF5252)),
      ],
    );
  }
}

// ---------- apps ----------

class _App {
  const _App(this.id, this.label, this.icon, this.color, {this.command, this.keys});
  final String id;
  final String label;
  final IconData icon;
  final Color color;
  final String? command; // typed into the Windows Run box
  final List<String>? keys; // or a key combination
}

const List<_App> _apps = [
  _App('browser', 'Browser', Icons.public_rounded, Color(0xFF4F8CFF), command: 'https://www.google.com'),
  _App('chrome', 'Chrome', Icons.language_rounded, Color(0xFFEA6A5A), command: 'chrome'),
  _App('edge', 'Edge', Icons.travel_explore_rounded, Color(0xFF1AA7A1), command: 'msedge'),
  _App('files', 'Files', Icons.folder_rounded, Color(0xFFE9A92B), keys: ['win', 'e']),
  _App('youtube', 'YouTube', Icons.smart_display_rounded, Color(0xFFE53935), command: 'https://www.youtube.com'),
  _App('notepad', 'Notepad', Icons.edit_note_rounded, Color(0xFF3FA7D6), command: 'notepad'),
  _App('calc', 'Calc', Icons.calculate_rounded, Color(0xFF3DBE7E), command: 'calc'),
  _App('paint', 'Paint', Icons.brush_rounded, Color(0xFFAB47BC), command: 'mspaint'),
  _App('terminal', 'Terminal', Icons.terminal_rounded, Color(0xFF455A64), command: 'cmd'),
  _App('taskmgr', 'Task Mgr', Icons.monitor_heart_rounded, Color(0xFFFF7043), keys: ['ctrl', 'shift', 'esc']),
  _App('settings', 'Settings', Icons.settings_rounded, Color(0xFF78909C), keys: ['win', 'i']),
  _App('control', 'Control', Icons.tune_rounded, Color(0xFF5C6BC0), command: 'control'),
  _App('snip', 'Snip', Icons.screenshot_monitor_rounded, Color(0xFF26A69A), keys: ['win', 'shift', 's']),
];

/// The real icon of a window open on the PC (sent by the server), or a letter tile until it arrives.
class _PcIcon extends StatelessWidget {
  const _PcIcon({required this.app, required this.icons, this.size = 40});

  final RunningApp app;
  final Map<String, Uint8List> icons;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bytes = icons[app.iconId];
    if (bytes != null) {
      return Image.memory(bytes, width: size, height: size, gaplessPlayback: true, filterQuality: FilterQuality.medium);
    }
    final name = app.title.isNotEmpty ? app.title : app.exe;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: _Ui.tile, borderRadius: BorderRadius.circular(size * 0.25)),
      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: TextStyle(color: Colors.white, fontSize: size * 0.45, fontWeight: FontWeight.w700)),
    );
  }
}

/// A rounded app tile in the app's colour.
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.app});

  final _App app;

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [app.color, Color.lerp(app.color, Colors.black, 0.35)!],
        ),
      ),
      child: Icon(app.icon, color: Colors.white, size: size * 0.55),
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
