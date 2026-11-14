import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/update_service.dart';
import 'common.dart';

/// "Connect your PC": four illustrated steps (swipe) and the two copy buttons.
class PcSetupCard extends StatefulWidget {
  const PcSetupCard({super.key});

  @override
  State<PcSetupCard> createState() => _PcSetupCardState();
}

class _PcSetupCardState extends State<PcSetupCard> {
  final PageController _page = PageController();
  int _i = 0;

  static const _titles = [
    'Copy the install command',
    'Paste it in PowerShell on the PC',
    'Open the app and pick your PC',
    'Press Allow on the PC',
  ];
  static const _texts = [
    'Tap "Copy command" below, then send it to your PC with WhatsApp, Telegram or email.',
    'On the PC press the Windows key, type powershell and press Enter. Paste with Ctrl+V and press Enter.',
    'Tap "Connect to a PC". Your PC shows up in the Wi-Fi tab. QR code and Manual work too.',
    'A window opens on the PC with a 6-digit code. If it matches the one on the phone, press Allow.',
  ];

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showSnack(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1D2F52), Color(0xFF111A2E)],
        ),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(13)),
                child: Icon(Icons.computer_rounded, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Connect your PC', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: Colors.white)),
                    Text('About 2 minutes, only once', style: text.bodySmall?.copyWith(color: Colors.white60)),
                  ],
                ),
              ),
              Text('${_i + 1} / 4', style: text.labelLarge?.copyWith(color: Colors.white60)),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 292,
            child: PageView.builder(
              controller: _page,
              itemCount: 4,
              onPageChanged: (i) => setState(() => _i = i),
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 160,
                      width: double.infinity,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(20)),
                      child: _art(i),
                    ),
                    const SizedBox(height: 12),
                    Text(_titles[i], style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text(_texts[i], maxLines: 4, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: Colors.white70)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var d = 0; d < 4; d++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: d == _i ? 20 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: d == _i ? cs.primary : Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: FilledButton.icon(
                  onPressed: () => _copy(kPcInstallCommand, 'Command copied. Send it to your PC.'),
                  icon: const Icon(Icons.terminal_rounded, size: 18),
                  label: const Text('Copy command'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FilledButton.tonalIcon(
                  onPressed: () => _copy(kPcDownloadPage, 'Link copied. Send it to your PC.'),
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: const Text('Copy link'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Windows says "protected your PC" when you use the link? The command does not.',
            style: text.bodySmall?.copyWith(color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _art(int i) {
    switch (i) {
      case 0:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Phone(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.terminal_rounded, color: Colors.white70, size: 22),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFF2F7DF6), borderRadius: BorderRadius.circular(10)),
                    child: const Text('Copy', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.send_rounded, color: Colors.white54, size: 24),
            const SizedBox(width: 12),
            const Icon(Icons.desktop_windows_rounded, color: Color(0xFF8BB8FF), size: 64),
          ],
        );
      case 1:
        return _Win(
          title: 'Windows PowerShell',
          width: 250,
          body: const ColoredBox(
            color: Color(0xFF012456),
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('PS C:\\> irm remotemouse-1ib.pages.dev/install.ps1 | iex',
                      style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 9.5, height: 1.4)),
                  SizedBox(height: 6),
                  Text('Downloading Remote Mouse...', style: TextStyle(color: Color(0xFFB7D7FF), fontFamily: 'monospace', fontSize: 9.5)),
                  Text('Starting the installer...', style: TextStyle(color: Color(0xFFB7D7FF), fontFamily: 'monospace', fontSize: 9.5)),
                ],
              ),
            ),
          ),
        );
      case 2:
        return _Phone(
          w: 104,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                color: const Color(0xFF171D28),
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: const Text('Connect to a PC', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 6),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: const Color(0xFF2F7DF6).withValues(alpha: 0.3), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF2F7DF6))),
                child: const Row(
                  children: [
                    Icon(Icons.desktop_windows_rounded, color: Colors.white, size: 14),
                    SizedBox(width: 4),
                    Expanded(child: Text('MY-PC', maxLines: 1, style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700))),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 6),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
                child: const Row(
                  children: [
                    Icon(Icons.laptop_rounded, color: Colors.white38, size: 14),
                    SizedBox(width: 4),
                    Expanded(child: Text('OFFICE', maxLines: 1, style: TextStyle(color: Colors.white38, fontSize: 9))),
                  ],
                ),
              ),
            ],
          ),
        );
      default:
        return _Win(
          title: 'Remote Mouse',
          width: 220,
          body: ColoredBox(
            color: const Color(0xFF171D28),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Allow this phone?', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('482 913', style: TextStyle(color: Color(0xFF8BB8FF), fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 2)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(6)),
                        child: const Text('Deny', style: TextStyle(color: Colors.white70, fontSize: 10)),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
                        decoration: BoxDecoration(color: const Color(0xFF2F7DF6), borderRadius: BorderRadius.circular(6)),
                        child: const Text('Allow', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }
}

/// A small phone drawing.
class _Phone extends StatelessWidget {
  const _Phone({required this.child, this.w = 84});

  final Widget child;
  final double w;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: w,
      height: 132,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F16),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white30, width: 2),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(11), child: child),
    );
  }
}

/// A small Windows-style window drawing.
class _Win extends StatelessWidget {
  const _Win({required this.title, required this.body, required this.width});

  final String title;
  final Widget body;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white30),
        color: const Color(0xFF0B0F16),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 20,
              color: const Color(0xFF2B3240),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(child: Text(title, maxLines: 1, style: const TextStyle(color: Colors.white70, fontSize: 9))),
                  const Icon(Icons.close_rounded, size: 11, color: Colors.white54),
                ],
              ),
            ),
            body,
          ],
        ),
      ),
    );
  }
}
