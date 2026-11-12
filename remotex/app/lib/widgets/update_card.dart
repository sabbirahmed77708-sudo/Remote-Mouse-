import 'package:flutter/material.dart';

import '../services/update_service.dart';

/// Shows the update state and the button for it. Renders nothing when there is nothing to show.
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, required this.update, this.compact = false});

  final UpdateController update;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: update,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final s = update.stage;
        final info = update.info;
        if (!update.hasUpdate && !(s == UpdateStage.failed && info != null && info.available)) {
          return const SizedBox.shrink();
        }
        final busy = s == UpdateStage.downloading || s == UpdateStage.installing;
        return Container(
          width: double.infinity,
          margin: EdgeInsets.only(bottom: compact ? 16 : 0),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(22)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.system_update_rounded, color: cs.onPrimaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('New version ${info!.latest} is ready',
                        style: text.titleSmall?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              if (!compact && info.notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(info.notes, maxLines: 5, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: cs.onPrimaryContainer)),
              ],
              const SizedBox(height: 12),
              if (s == UpdateStage.downloading) ...[
                LinearProgressIndicator(value: update.progress > 0 ? update.progress : null),
                const SizedBox(height: 6),
                Text('Downloading ${(update.progress * 100).round()}%', style: text.bodySmall?.copyWith(color: cs.onPrimaryContainer)),
              ] else if (s == UpdateStage.installing)
                Text('Opening the installer...', style: text.bodyMedium?.copyWith(color: cs.onPrimaryContainer))
              else ...[
                if (s == UpdateStage.needsPermission)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text('Allow Remote Mouse to install updates in the screen that opened, come back and press Update again.',
                        style: text.bodyMedium?.copyWith(color: cs.onPrimaryContainer)),
                  ),
                if (s == UpdateStage.failed && update.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(update.error!, style: text.bodyMedium?.copyWith(color: cs.error, fontWeight: FontWeight.w600)),
                  ),
                FilledButton.icon(
                  onPressed: busy ? null : update.install,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(s == UpdateStage.failed ? 'Try again' : 'Update now'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
