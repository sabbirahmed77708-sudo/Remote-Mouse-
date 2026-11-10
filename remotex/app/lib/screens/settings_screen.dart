import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_scope.dart';
import '../services/update_service.dart';
import '../widgets/common.dart';
import '../widgets/logo.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final app = scope.app;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text('Settings', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SectionTitle('Appearance'),
            _Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_rounded), label: Text('System')),
                    ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_rounded), label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_rounded), label: Text('Dark')),
                  ],
                  selected: {app.themeMode},
                  onSelectionChanged: (s) => app.themeMode = s.first,
                ),
              ),
            ),
            const SectionTitle('Touchpad'),
            _Card(
              child: Column(
                children: [
                  _SliderTile(
                    icon: Icons.speed_rounded,
                    title: 'Pointer speed',
                    value: app.pointerSpeed,
                    min: 0.5,
                    max: 4,
                    onChanged: (v) => app.pointerSpeed = v,
                  ),
                  const Divider(height: 1),
                  _SliderTile(
                    icon: Icons.swap_vert_rounded,
                    title: 'Scroll speed',
                    value: app.scrollSpeed,
                    min: 0.3,
                    max: 3,
                    onChanged: (v) => app.scrollSpeed = v,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.swipe_vertical_rounded),
                    title: const Text('Natural scrolling'),
                    subtitle: const Text('Content follows your fingers, like on a phone'),
                    value: app.naturalScroll,
                    onChanged: (v) => app.naturalScroll = v,
                  ),
                ],
              ),
            ),
            const SectionTitle('Feedback'),
            _Card(
              child: SwitchListTile(
                secondary: const Icon(Icons.vibration_rounded),
                title: const Text('Haptic feedback'),
                subtitle: const Text('A small vibration when you click or press a key'),
                value: app.haptics,
                onChanged: (v) {
                  app.haptics = v;
                  app.haptic(strong: true);
                },
              ),
            ),
            const SectionTitle('Connection'),
            _Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.autorenew_rounded),
                    title: const Text('Reconnect automatically'),
                    subtitle: const Text('Also reconnects to your last PC when the app opens'),
                    value: app.autoReconnect,
                    onChanged: (v) => app.autoReconnect = v,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.smartphone_rounded),
                    title: const Text('This phone\'s name'),
                    subtitle: Text('${app.deviceName}  -  shown in RemoteX Server on the PC'),
                    onTap: () => _editName(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.delete_sweep_rounded, color: cs.error),
                    title: Text('Forget all saved PCs', style: TextStyle(color: cs.error)),
                    subtitle: Text(app.pcs.isEmpty ? 'No saved PCs' : '${app.pcs.length} saved'),
                    enabled: app.pcs.isNotEmpty,
                    onTap: () => _forgetAll(context),
                  ),
                ],
              ),
            ),
            const SectionTitle('About'),
            const _Card(child: _AboutCard()),
          ],
        );
      },
    );
  }

  Future<void> _editName(BuildContext context) async {
    final app = AppScope.read(context).app;
    final controller = TextEditingController(text: app.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Phone name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'e.g. Sabbir\'s phone'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name != null) app.deviceName = name;
  }

  Future<void> _forgetAll(BuildContext context) async {
    final scope = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget all PCs?'),
        content: const Text('You will have to pair with each PC again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Forget')),
        ],
      ),
    );
    if (ok == true) {
      await scope.conn.disconnect();
      await scope.app.clearPcs();
    }
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 16),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.bodyLarge)),
              Text(value.toStringAsFixed(1), style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
          Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _AboutCard extends StatefulWidget {
  const _AboutCard();

  @override
  State<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<_AboutCard> {
  bool _checking = false;
  UpdateInfo? _info;
  String? _error;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final info = await checkForUpdate();
      if (!mounted) return;
      setState(() => _info = info);
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _info = null;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _open(String url) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) showSnack(context, 'Could not open the browser. Open $kReleasesPage yourself.', error: true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final info = _info;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const LogoMark(size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('RemoteX', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    Text('Version $kAppVersion', style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Encrypted connection (TLS, pinned certificate). Protocol v1.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 14),
          if (info != null && info.available) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(18)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Update available: ${info.latest}',
                      style: text.titleSmall?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
                  if (info.notes.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(info.notes,
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: cs.onPrimaryContainer)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => _open(info.apkUrl ?? info.pageUrl),
              icon: const Icon(Icons.download_rounded),
              label: const Text('Download update'),
            ),
            const SizedBox(height: 4),
            Text('Open the downloaded file to install it over this version. Your paired PCs are kept.',
                style: text.bodySmall?.copyWith(color: cs.outline)),
          ] else ...[
            if (info != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: cs.primary, size: 20),
                    const SizedBox(width: 8),
                    Text('You have the latest version.', style: text.bodyMedium),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error!, style: text.bodyMedium?.copyWith(color: cs.error)),
              ),
            FilledButton.tonalIcon(
              onPressed: _checking ? null : _check,
              icon: _checking
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.system_update_rounded),
              label: Text(_checking ? 'Checking...' : 'Check for updates'),
            ),
          ],
          const SizedBox(height: 4),
          TextButton(onPressed: () => _open(kReleasesPage), child: const Text('All versions on GitHub')),
        ],
      ),
    );
  }
}
