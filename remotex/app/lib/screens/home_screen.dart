import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../models/saved_pc.dart';
import '../services/connection_controller.dart';
import '../services/update_service.dart';
import '../widgets/common.dart';
import '../widgets/logo.dart';
import '../widgets/update_card.dart';

/// Dashboard: connection card, quick actions and saved PCs.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onNavigate, required this.onConnect});

  final ValueChanged<int> onNavigate;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.app, scope.conn]),
      builder: (context, _) {
        final conn = scope.conn;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Row(
              children: [
                const LogoMark(size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Remote Mouse', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: () => onNavigate(4),
                  icon: const Icon(Icons.settings_rounded),
                ),
              ],
            ),
            const SizedBox(height: 18),
            UpdateCard(update: scope.update, compact: true),
            _ConnectionCard(conn: conn, onConnect: onConnect),
            const SectionTitle('Control'),
            Row(
              children: [
                Expanded(child: _ActionTile(icon: Icons.touch_app_rounded, label: 'Touchpad', onTap: () => onNavigate(1))),
                const SizedBox(width: 12),
                Expanded(child: _ActionTile(icon: Icons.keyboard_rounded, label: 'Keyboard', onTap: () => onNavigate(2))),
                const SizedBox(width: 12),
                Expanded(child: _ActionTile(icon: Icons.play_circle_rounded, label: 'Media', onTap: () => onNavigate(3))),
              ],
            ),
            const SectionTitle('Saved PCs'),
            if (scope.app.pcs.isEmpty) ...[
              const _PcSetupCard(),
              const SizedBox(height: 10),
              _EmptyCard(onConnect: onConnect),
            ] else
              for (final pc in scope.app.pcs) _PcTile(pc: pc, active: conn.pc?.id == pc.id && conn.connected),
          ],
        );
      },
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.conn, required this.onConnect});

  final ConnectionController conn;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = LinkStyle.of(conn);
    final connected = conn.connected;
    final text = Theme.of(context).textTheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: connected
              ? [cs.primary, cs.tertiary]
              : [cs.surfaceContainerHigh, cs.surfaceContainerHighest],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Icon(style.icon, key: ValueKey(conn.state), color: connected ? cs.onPrimary : style.color, size: 28),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  style.label,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: connected ? cs.onPrimary : cs.onSurface),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            connected
                ? '${conn.pc?.host ?? ''}${conn.latencyMs != null ? '  -  ${conn.latencyMs} ms' : ''}'
                : (conn.error ?? 'Open Remote Mouse Server on your PC, then connect.'),
            style: text.bodyMedium?.copyWith(
              color: connected
                  ? cs.onPrimary.withValues(alpha: 0.85)
                  : (conn.state == LinkState.failed ? cs.error : cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 18),
          if (connected)
            FilledButton.tonalIcon(
              onPressed: conn.disconnect,
              icon: const Icon(Icons.link_off_rounded),
              label: const Text('Disconnect'),
            )
          else if (conn.busy)
            Row(
              children: [
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 12),
                TextButton(onPressed: conn.disconnect, child: const Text('Cancel')),
              ],
            )
          else
            FilledButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.computer_rounded),
              label: const Text('Connect to a PC'),
            ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.secondaryContainer,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            children: [
              Icon(icon, size: 32, color: cs.onSecondaryContainer),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSecondaryContainer)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.onConnect});
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(Icons.qr_code_scanner_rounded, size: 34, color: cs.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Text('No PCs yet. Pair one by scanning the QR code in Remote Mouse Server.',
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
            TextButton(onPressed: onConnect, child: const Text('Pair')),
          ],
        ),
      ),
    );
  }
}

class _PcTile extends StatelessWidget {
  const _PcTile({required this.pc, required this.active});

  final SavedPc pc;
  final bool active;

  String _ago() {
    if (pc.lastConnected == 0) return 'never connected';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(pc.lastConnected));
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: active ? cs.primaryContainer : cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          leading: Icon(Icons.laptop_windows_rounded, color: active ? cs.onPrimaryContainer : cs.primary),
          title: Text(pc.name, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('${pc.host}  -  ${active ? 'connected' : _ago()}'),
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'forget') {
                if (scope.conn.pc?.id == pc.id) await scope.conn.disconnect();
                await scope.app.removePc(pc.id);
              } else if (v == 'connect') {
                final ok = await scope.conn.connectSaved(pc);
                if (!ok && context.mounted) showSnack(context, scope.conn.error ?? 'Could not connect', error: true);
              }
            },
            itemBuilder: (_) => [
              if (!active) const PopupMenuItem(value: 'connect', child: Text('Connect')),
              const PopupMenuItem(value: 'forget', child: Text('Forget this PC')),
            ],
          ),
          onTap: active
              ? null
              : () async {
                  scope.app.haptic();
                  final ok = await scope.conn.connectSaved(pc);
                  if (!ok && context.mounted) showSnack(context, scope.conn.error ?? 'Could not connect', error: true);
                },
        ),
      ),
    );
  }
}

/// Tells the user how to get the tiny PC helper, without leaving the app.
class _PcSetupCard extends StatelessWidget {
  const _PcSetupCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cs.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.computer_rounded, color: cs.onPrimaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Step 1: set up your PC (once)',
                      style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: cs.onPrimaryContainer)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'This phone app is the only app you use. Your PC just needs a small helper installed once; '
              'it runs quietly in the background and asks you to press Allow. On the PC open this link and '
              'download "Remote-Mouse-Setup.exe". If Windows shows "Windows protected your PC", use the install command instead: '
              'paste it into PowerShell on the PC and the warning does not appear.',
              style: text.bodyMedium?.copyWith(color: cs.onPrimaryContainer),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(const ClipboardData(text: kPcDownloadPage));
                    if (context.mounted) showSnack(context, 'Link copied. Send it to your PC.');
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy link'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await Clipboard.setData(const ClipboardData(text: kPcInstallCommand));
                    if (context.mounted) {
                      showSnack(context, 'Command copied. On the PC open PowerShell, paste it and press Enter.');
                    }
                  },
                  icon: const Icon(Icons.terminal_rounded),
                  label: const Text('Copy install command'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
