import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/saved_pc.dart';
import '../services/connection_controller.dart';
import '../widgets/common.dart';
import '../widgets/logo.dart';
import '../widgets/pc_setup_card.dart';
import '../widgets/update_card.dart';

/// Dashboard: connection card, quick actions and saved PCs.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onNavigate, required this.onConnect});

  final ValueChanged<int> onNavigate;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([scope.app, scope.conn]),
      builder: (context, _) {
        final conn = scope.conn;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            Row(
              children: [
                const LogoMark(size: 50),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Remote Mouse', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                      Text('Your phone as mouse, keyboard and screen', style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Settings',
                  onPressed: () => onNavigate(4),
                  icon: const Icon(Icons.settings_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            UpdateCard(update: scope.update, compact: true),
            _ConnectionCard(conn: conn, onConnect: onConnect, onOpen: () => onNavigate(1)),
            const SectionTitle('Control'),
            Row(
              children: [
                Expanded(
                  child: _ActionTile(
                    icon: Icons.touch_app_rounded,
                    label: 'Touchpad',
                    caption: 'Move, click',
                    color: const Color(0xFF4F8CFF),
                    onTap: () => onNavigate(1),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionTile(
                    icon: Icons.keyboard_rounded,
                    label: 'Keyboard',
                    caption: 'Type on PC',
                    color: const Color(0xFF2EBD6B),
                    onTap: () => onNavigate(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionTile(
                    icon: Icons.play_circle_rounded,
                    label: 'Media',
                    caption: 'Play, volume',
                    color: const Color(0xFFF59E0B),
                    onTap: () => onNavigate(3),
                  ),
                ),
              ],
            ),
            const SectionTitle('Saved PCs'),
            if (scope.app.pcs.isEmpty)
              _EmptyCard(onConnect: onConnect)
            else
              for (final pc in scope.app.pcs) _PcTile(pc: pc, active: conn.pc?.id == pc.id && conn.connected),
            // the illustrated guide lives in a sheet, so the home stays on one page
            const SizedBox(height: 12),
            _SetupTile(
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                backgroundColor: Colors.transparent,
                builder: (_) => const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: SingleChildScrollView(child: PcSetupCard()),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.conn, required this.onConnect, required this.onOpen});

  final ConnectionController conn;
  final VoidCallback onConnect;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = LinkStyle.of(conn);
    final connected = conn.connected;
    final text = Theme.of(context).textTheme;
    final sub = connected
        ? '${conn.pc?.host ?? ''}${conn.latencyMs != null ? '   ${conn.latencyMs} ms' : ''}${conn.viaBluetooth ? '   Bluetooth' : ''}'
        : (conn.error ?? 'Open Remote Mouse on your PC, then connect.');
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: connected ? const [Color(0xFF1FA971), Color(0xFF0D6B50)] : const [Color(0xFF1D2F52), Color(0xFF111A2E)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: connected ? 0.0 : 0.1)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -22,
            top: -18,
            child: Icon(Icons.desktop_windows_rounded, size: 150, color: Colors.white.withValues(alpha: 0.07)),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(16)),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Icon(style.icon, key: ValueKey(conn.state), color: connected ? Colors.white : style.color, size: 26),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            connected ? (conn.pc?.name ?? 'PC') : style.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: Colors.white),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            connected ? 'Connected' : (conn.busy ? 'Please wait...' : 'Ready when you are'),
                            style: text.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.8), fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  sub,
                  style: text.bodyMedium?.copyWith(
                    color: conn.state == LinkState.failed && !connected ? const Color(0xFFFFB4B0) : Colors.white.withValues(alpha: 0.82),
                  ),
                ),
                const SizedBox(height: 18),
                if (connected)
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF0D6B50)),
                          onPressed: onOpen,
                          icon: const Icon(Icons.touch_app_rounded),
                          label: const Text('Open remote'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.18), foregroundColor: Colors.white),
                        onPressed: conn.disconnect,
                        icon: const Icon(Icons.link_off_rounded),
                        label: const Text('Disconnect'),
                      ),
                    ],
                  )
                else if (conn.busy)
                  Row(
                    children: [
                      const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      const SizedBox(width: 14),
                      TextButton(onPressed: conn.disconnect, child: const Text('Cancel')),
                    ],
                  )
                else
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
                    onPressed: onConnect,
                    icon: const Icon(Icons.computer_rounded),
                    label: const Text('Connect to a PC'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.caption, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final String caption;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
          ),
          child: Column(
            children: [
              IconChip(icon, color: color, size: 48),
              const SizedBox(height: 10),
              Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const IconChip(Icons.qr_code_scanner_rounded, size: 46),
          const SizedBox(width: 14),
          Expanded(
            child: Text('No PCs yet. Pair one by scanning the QR code in Remote Mouse Server.',
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          TextButton(onPressed: onConnect, child: const Text('Pair')),
        ],
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
    const green = Color(0xFF2EBD6B);
    Future<void> connect() async {
      scope.app.haptic();
      final ok = await scope.conn.connectSaved(pc);
      if (!ok && context.mounted) showSnack(context, scope.conn.error ?? 'Could not connect', error: true);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: active ? null : connect,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: active ? green.withValues(alpha: 0.6) : cs.outlineVariant.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                IconChip(Icons.laptop_windows_rounded, color: active ? green : cs.primary, size: 46),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(pc.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (active) ...[
                            Container(width: 7, height: 7, decoration: const BoxDecoration(color: green, shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              '${pc.host}   ${active ? 'connected' : _ago()}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: active ? green : cs.onSurfaceVariant, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'forget') {
                      if (scope.conn.pc?.id == pc.id) await scope.conn.disconnect();
                      await scope.app.removePc(pc.id);
                    } else if (v == 'connect') {
                      await connect();
                    }
                  },
                  itemBuilder: (_) => [
                    if (!active) const PopupMenuItem(value: 'connect', child: Text('Connect')),
                    const PopupMenuItem(value: 'forget', child: Text('Forget this PC')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class _SetupTile extends StatelessWidget {
  const _SetupTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(colors: [Color(0xFF1D2F52), Color(0xFF111A2E)]),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            const IconChip(Icons.computer_rounded, color: Color(0xFF8AB4FF)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Set up a PC', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text('Step-by-step guide with pictures', style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.keyboard_arrow_up_rounded, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
