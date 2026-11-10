import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../widgets/common.dart';

/// Media remote: play/pause, next, previous, stop, volume and mute.
class MediaScreen extends StatelessWidget {
  const MediaScreen({super.key, required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;

    Widget tile(String key, IconData icon, String label,
        {bool repeat = false, bool primary = false, double height = 96}) {
      return PressableTile(
        immediate: true,
        repeat: repeat,
        radius: primary ? 32 : 26,
        color: primary ? cs.primary : cs.surfaceContainerHigh,
        pressedColor: primary ? cs.primaryContainer : cs.secondaryContainer,
        semanticLabel: label,
        onPress: () {
          scope.app.haptic(strong: primary);
          scope.conn.media(key);
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: primary ? 46 : 32, color: primary ? cs.onPrimary : cs.onSurface),
            const SizedBox(height: 4),
            Text(label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: primary ? cs.onPrimary : cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    return ListenableBuilder(
      listenable: scope.conn,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(alignment: Alignment.centerLeft, child: StatusPill(conn: scope.conn, onTap: onConnect)),
              const SizedBox(height: 16),
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    Expanded(child: tile('prev', Icons.skip_previous_rounded, 'Previous')),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: tile('playpause', Icons.play_arrow_rounded, 'Play / Pause', primary: true)),
                    const SizedBox(width: 12),
                    Expanded(child: tile('next', Icons.skip_next_rounded, 'Next')),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Expanded(child: tile('voldown', Icons.volume_down_rounded, 'Volume -', repeat: true)),
                    const SizedBox(width: 12),
                    Expanded(child: tile('mute', Icons.volume_off_rounded, 'Mute')),
                    const SizedBox(width: 12),
                    Expanded(child: tile('volup', Icons.volume_up_rounded, 'Volume +', repeat: true)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(height: 64, width: double.infinity, child: tile('stop', Icons.stop_rounded, 'Stop')),
              if (!scope.conn.connected)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Center(
                    child: TextButton.icon(
                      onPressed: onConnect,
                      icon: const Icon(Icons.computer_rounded),
                      label: const Text('Connect to a PC to use the remote'),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
