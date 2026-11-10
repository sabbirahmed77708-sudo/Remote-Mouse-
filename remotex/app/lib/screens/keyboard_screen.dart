import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../widgets/common.dart';

/// Live text input plus every special key and common shortcut.
class KeyboardScreen extends StatefulWidget {
  const KeyboardScreen({super.key, required this.onConnect});

  final VoidCallback onConnect;

  @override
  State<KeyboardScreen> createState() => _KeyboardScreenState();
}

class _KeyboardScreenState extends State<KeyboardScreen> {
  static const _modOrder = ['ctrl', 'alt', 'shift', 'win'];
  static const _modLabel = {'ctrl': 'Ctrl', 'alt': 'Alt', 'shift': 'Shift', 'win': 'Win'};

  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  final Set<String> _mods = {};
  List<int> _prev = const [];

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<String> get _activeMods => [for (final m in _modOrder) if (_mods.contains(m)) m];

  void _resetField() {
    _ctrl.value = TextEditingValue.empty;
    _prev = const [];
  }

  /// Sends only what changed since the last edit: backspaces for deleted characters, then new text.
  void _onChanged(String value) {
    final scope = AppScope.read(context);
    final cur = value.runes.toList();
    var p = 0;
    final m = cur.length < _prev.length ? cur.length : _prev.length;
    while (p < m && cur[p] == _prev[p]) {
      p++;
    }
    final deleted = _prev.length - p;
    final added = cur.sublist(p);
    if (deleted > 0) scope.conn.key('backspace', count: deleted > 50 ? 50 : deleted);
    if (added.isNotEmpty) {
      final text = String.fromCharCodes(added);
      final mods = _activeMods;
      if (mods.isNotEmpty && added.length == 1 && RegExp(r'^[a-zA-Z0-9]$').hasMatch(text)) {
        scope.conn.combo([...mods, text.toLowerCase()]);
        setState(_mods.clear);
        _resetField();
        return;
      }
      scope.conn.typeText(text);
    }
    _prev = cur;
    if (value.contains('\n') || cur.length > 120) _resetField();
  }

  void _pressKey(String key) {
    final scope = AppScope.read(context);
    scope.app.haptic();
    final mods = _activeMods;
    if (mods.isNotEmpty) {
      scope.conn.combo([...mods, key]);
      setState(_mods.clear);
    } else {
      scope.conn.key(key);
    }
  }

  void _combo(List<String> keys) {
    final scope = AppScope.read(context);
    scope.app.haptic();
    scope.conn.combo(keys);
  }

  Widget _key(String label, String key, {bool repeat = false, double width = 76, IconData? icon}) {
    return SizedBox(
      width: width,
      height: 48,
      child: PressableTile(
        radius: 14,
        repeat: repeat,
        semanticLabel: label,
        onPress: () => _pressKey(key),
        child: icon != null ? Icon(icon, size: 22) : Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _shortcut(String label, List<String> keys, {IconData? icon}) {
    return SizedBox(
      height: 44,
      child: PressableTile(
        radius: 14,
        semanticLabel: label,
        onPress: () => _combo(keys),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 6)],
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conn = AppScope.of(context).conn;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: conn,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          children: [
            Align(alignment: Alignment.centerLeft, child: StatusPill(conn: conn, onTap: widget.onConnect)),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              focusNode: _focus,
              enabled: conn.connected,
              minLines: 3,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: conn.connected ? 'Type here - it appears on your PC' : 'Connect to a PC to type',
                filled: true,
                fillColor: cs.surfaceContainerHigh,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                suffixIcon: IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.backspace_outlined),
                  onPressed: _resetField,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final m in _modOrder)
                  FilterChip(
                    label: Text(_modLabel[m]!),
                    selected: _mods.contains(m),
                    showCheckmark: false,
                    onSelected: (v) {
                      AppScope.read(context).app.haptic();
                      setState(() => v ? _mods.add(m) : _mods.remove(m));
                    },
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 10),
              child: Text(
                'Tap Ctrl / Alt / Shift / Win first, then a key.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _key('Esc', 'esc'),
                _key('Tab', 'tab'),
                _key('Enter', 'enter'),
                _key('Backspace', 'backspace', repeat: true, icon: Icons.backspace_rounded),
                _key('Del', 'delete', repeat: true),
                _key('Home', 'home'),
                _key('End', 'end'),
                _key('PgUp', 'pgup', repeat: true),
                _key('PgDn', 'pgdn', repeat: true),
                _key('Space', 'space', repeat: true, width: 160),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: SizedBox(
                width: 76 * 3 + 16,
                child: Column(
                  children: [
                    _key('Up', 'up', repeat: true, width: 76, icon: Icons.keyboard_arrow_up_rounded),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _key('Left', 'left', repeat: true, icon: Icons.keyboard_arrow_left_rounded),
                        _key('Down', 'down', repeat: true, icon: Icons.keyboard_arrow_down_rounded),
                        _key('Right', 'right', repeat: true, icon: Icons.keyboard_arrow_right_rounded),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 12,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => _key('F${i + 1}', 'f${i + 1}', width: 60),
              ),
            ),
            const SectionTitle('Shortcuts'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _shortcut('Copy', ['ctrl', 'c'], icon: Icons.copy_rounded),
                _shortcut('Paste', ['ctrl', 'v'], icon: Icons.paste_rounded),
                _shortcut('Cut', ['ctrl', 'x'], icon: Icons.content_cut_rounded),
                _shortcut('Select all', ['ctrl', 'a'], icon: Icons.select_all_rounded),
                _shortcut('Undo', ['ctrl', 'z'], icon: Icons.undo_rounded),
                _shortcut('Redo', ['ctrl', 'y'], icon: Icons.redo_rounded),
                _shortcut('Save', ['ctrl', 's'], icon: Icons.save_rounded),
                _shortcut('Alt+Tab', ['alt', 'tab'], icon: Icons.tab_rounded),
                _shortcut('Desktop', ['win', 'd'], icon: Icons.desktop_windows_rounded),
                _shortcut('Task manager', ['ctrl', 'shift', 'esc'], icon: Icons.monitor_heart_rounded),
                _shortcut('Close window', ['alt', 'f4'], icon: Icons.close_rounded),
                _shortcut('Lock', ['win', 'l'], icon: Icons.lock_rounded),
              ],
            ),
          ],
        );
      },
    );
  }
}
