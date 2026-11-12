import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/connection_controller.dart';
import '../widgets/app_icon.dart';
import '../widgets/common.dart';

class _Launcher {
  const _Launcher(this.key, this.label, this.icon);
  final String key; // the name the PC understands (PROTOCOL.md, "Open windows and apps")
  final String label;
  final IconData icon;
}

const _launchers = <_Launcher>[
  _Launcher('chrome', 'Chrome', Icons.public_rounded),
  _Launcher('edge', 'Edge', Icons.language_rounded),
  _Launcher('explorer', 'Files', Icons.folder_rounded),
  _Launcher('notepad', 'Notepad', Icons.edit_note_rounded),
  _Launcher('calc', 'Calculator', Icons.calculate_rounded),
  _Launcher('taskmgr', 'Task Manager', Icons.monitor_heart_rounded),
  _Launcher('paint', 'Paint', Icons.brush_rounded),
  _Launcher('settings', 'Settings', Icons.settings_rounded),
  _Launcher('snip', 'Snip', Icons.content_cut_rounded),
];

/// Everything that is open on the PC (tap to bring to the front, X to close) and a row of apps to start.
class AppsScreen extends StatelessWidget {
  const AppsScreen({super.key, required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final conn = AppScope.of(context).conn;
    return ListenableBuilder(
      listenable: conn,
      builder: (context, _) {
        final ready = conn.connected && !conn.viaBluetooth;
        final windows = conn.windows;
        return RefreshIndicator(
          onRefresh: () async {
            conn.refreshWindows();
            await Future<void>.delayed(const Duration(milliseconds: 600));
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Align(alignment: Alignment.centerLeft, child: StatusPill(conn: conn, onTap: onConnect)),
              if (!ready)
                _Notice(
                  icon: conn.viaBluetooth ? Icons.bluetooth_rounded : Icons.computer_rounded,
                  text: conn.viaBluetooth
                      ? 'Open windows need the Wi-Fi link. Over Bluetooth the phone works as a mouse and keyboard only.'
                      : 'Connect to a PC to see what is open on it.',
                  action: conn.viaBluetooth ? null : onConnect,
                )
              else ...[
                _SectionHeader(title: 'Open now', count: windows.length),
                if (windows.isEmpty)
                  const _Notice(icon: Icons.web_asset_off_rounded, text: 'No open windows found on the PC.')
                else
                  for (final w in windows) _WindowTile(key: ValueKey(w.id), window: w, active: w.id == conn.foregroundId),
              ],
              const SectionTitle('Open an app'),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.25,
                children: [for (final l in _launchers) _LauncherTile(launcher: l, enabled: ready)],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(12)),
            child: Text('$count', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSecondaryContainer)),
          ),
          const Spacer(),
          Text('Pull down to refresh', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline)),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(icon, size: 30, color: cs.outline),
              const SizedBox(width: 14),
              Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
              if (action != null) TextButton(onPressed: action, child: const Text('Connect')),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowTile extends StatelessWidget {
  const _WindowTile({super.key, required this.window, required this.active});

  final RemoteWindow window;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    final conn = scope.conn;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final subtitle = window.minimized ? '${window.appName}  -  minimized' : window.appName;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: active ? cs.primaryContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            scope.app.haptic();
            conn.windowAction('focus', window.id);
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              children: [
                AppIcon(conn: conn, app: window.app, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        window.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700, color: active ? cs.onPrimaryContainer : cs.onSurface),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (action) => conn.windowAction(action, window.id),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'focus', child: Text('Bring to front')),
                    const PopupMenuItem(value: 'min', child: Text('Minimize')),
                    const PopupMenuItem(value: 'max', child: Text('Maximize')),
                    const PopupMenuItem(value: 'restore', child: Text('Restore')),
                  ],
                ),
                IconButton.filledTonal(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    scope.app.haptic(strong: true);
                    conn.windowAction('close', window.id);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LauncherTile extends StatelessWidget {
  const _LauncherTile({required this.launcher, required this.enabled});

  final _Launcher launcher;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled
              ? () {
                  final scope = AppScope.read(context);
                  scope.app.haptic();
                  scope.conn.launch(launcher.key);
                  showSnack(context, 'Opening ${launcher.label}...');
                }
              : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(launcher.icon, size: 28, color: cs.onSecondaryContainer),
              const SizedBox(height: 6),
              Text(
                launcher.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSecondaryContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
