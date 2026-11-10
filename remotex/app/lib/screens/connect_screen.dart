import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_scope.dart';
import '../models/saved_pc.dart';
import '../services/connection_controller.dart';
import '../services/discovery_service.dart';
import '../services/remotex_client.dart';
import '../widgets/common.dart';

/// Three ways to reach a PC: nearby (auto discovery), QR code, manual address.
/// Pops with `true` once connected.
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Connect to a PC'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.wifi_find_rounded), text: 'Nearby'),
            Tab(icon: Icon(Icons.qr_code_scanner_rounded), text: 'QR code'),
            Tab(icon: Icon(Icons.keyboard_rounded), text: 'Manual'),
          ]),
        ),
        body: const TabBarView(
          physics: NeverScrollableScrollPhysics(),
          children: [_NearbyTab(), _QrTab(), _ManualTab()],
        ),
      ),
    );
  }
}

/// Runs a connect attempt with a blocking progress dialog; pops the screen on success.
Future<void> _attempt(BuildContext context, Future<bool> Function() run) async {
  final conn = AppScope.read(context).conn;
  final navigator = Navigator.of(context);
  final ok = await run();
  if (ok) {
    AppScope.read(context).app.haptic(strong: true);
    navigator.pop(true);
  } else if (context.mounted) {
    showSnack(context, conn.error ?? 'Could not connect', error: true);
  }
}

// ---------------------------------------------------------------------------

class _NearbyTab extends StatefulWidget {
  const _NearbyTab();

  @override
  State<_NearbyTab> createState() => _NearbyTabState();
}

class _NearbyTabState extends State<_NearbyTab> {
  List<DiscoveredPc> _found = const [];
  bool _scanning = false;
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    final r = await discoverPcs();
    if (!mounted) return;
    setState(() {
      _found = r;
      _scanning = false;
      _scanned = true;
    });
  }

  Future<void> _tap(DiscoveredPc d) async {
    final scope = AppScope.read(context);
    final saved = scope.app.pcById(d.id);
    if (saved != null) {
      await _attempt(context, () => scope.conn.connectSaved(saved));
      return;
    }
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => _CodeDialog(name: d.name),
    );
    if (code == null || !mounted) return;
    await _attempt(context, () => scope.conn.pairManual(host: d.host, port: d.port, code: code));
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: scope.conn,
      builder: (context, _) {
        final busy = scope.conn.busy;
        return Column(
          children: [
            if (_scanning || busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'PCs on this Wi-Fi that are running RemoteX Server appear here.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  for (final d in _found)
                    Card(
                      elevation: 0,
                      color: cs.surfaceContainerHigh,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                      child: ListTile(
                        enabled: !busy,
                        leading: const Icon(Icons.laptop_windows_rounded),
                        title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${d.host}  -  ${scope.app.pcById(d.id) != null ? 'paired' : 'needs pairing code'}'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _tap(d),
                      ),
                    ),
                  if (_scanned && _found.isEmpty && !_scanning)
                    Padding(
                      padding: const EdgeInsets.only(top: 32),
                      child: Column(
                        children: [
                          Icon(Icons.search_off_rounded, size: 44, color: cs.outline),
                          const SizedBox(height: 12),
                          const Text('No PC found', textAlign: TextAlign.center),
                          const SizedBox(height: 6),
                          Text(
                            'Check that the phone and PC use the same Wi-Fi, RemoteX Server is open, '
                            'and Windows Firewall allowed it on Private networks. '
                            'Some routers block discovery - use the QR code or Manual tab instead.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  Center(
                    child: FilledButton.tonalIcon(
                      onPressed: _scanning || busy ? null : _scan,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Search again'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

class _QrTab extends StatefulWidget {
  const _QrTab();

  @override
  State<_QrTab> createState() => _QrTabState();
}

class _QrTabState extends State<_QrTab> {
  final MobileScannerController _camera = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  String? _hint;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      final link = PairingLink.parse(raw);
      if (link == null) {
        setState(() => _hint = 'That QR code is not a RemoteX pairing code.');
        continue;
      }
      _handled = true;
      final conn = AppScope.read(context).conn;
      await _attempt(context, () => conn.pairWithLink(link));
      if (mounted) _handled = false;
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MobileScanner(
                controller: _camera,
                onDetect: _onDetect,
                errorBuilder: (context, error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.no_photography_rounded, size: 44, color: cs.error),
                        const SizedBox(height: 12),
                        Text(
                          error.errorCode == MobileScannerErrorCode.permissionDenied
                              ? 'Camera permission was denied. Allow it in the phone settings, or use the Manual tab.'
                              : 'The camera is not available. Use the Manual tab instead.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Text(
            _hint ?? 'Open RemoteX Server on your PC and point the camera at the QR code.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: _hint == null ? cs.onSurfaceVariant : cs.error),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _ManualTab extends StatefulWidget {
  const _ManualTab();

  @override
  State<_ManualTab> createState() => _ManualTabState();
}

class _ManualTabState extends State<_ManualTab> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '$kWsPort');
  final _code = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final code = normalizeCode(_code.text);
    String? problem;
    if (host.isEmpty) {
      problem = 'Enter the PC address shown in RemoteX Server.';
    } else if (port == null || port < 1 || port > 65535) {
      problem = 'The port must be a number from 1 to 65535.';
    } else if (code.length != 12) {
      problem = 'The pairing code has 12 letters and digits.';
    }
    setState(() => _problem = problem);
    if (problem != null) return;
    FocusScope.of(context).unfocus();
    final conn = AppScope.read(context).conn;
    await _attempt(context, () => conn.pairManual(host: host, port: port!, code: code));
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: scope.conn,
      builder: (context, _) {
        final busy = scope.conn.busy;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Type the address and pairing code that RemoteX Server shows on your PC.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    enabled: !busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'PC address', hintText: '192.168.1.20', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _port,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _code,
              enabled: !busy,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Pairing code', hintText: 'ABCD-EFGH-JKMN', border: OutlineInputBorder()),
              onSubmitted: (_) => _go(),
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_problem!, style: TextStyle(color: cs.error)),
              ),
            if (scope.conn.state == LinkState.failed && scope.conn.error != null && _problem == null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(scope.conn.error!, style: TextStyle(color: cs.error)),
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: busy ? null : _go,
              icon: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link_rounded),
              label: Text(busy ? 'Connecting...' : 'Pair and connect'),
            ),
            const SizedBox(height: 14),
            Text(
              'Tip: the QR code is safer than typing - it also carries the PC\'s certificate fingerprint, '
              'so a fake PC on the network cannot be paired by mistake.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
          ],
        );
      },
    );
  }
}

class _CodeDialog extends StatefulWidget {
  const _CodeDialog({required this.name});
  final String name;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _c = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final code = normalizeCode(_c.text);
    if (code.length != 12) {
      setState(() => _err = 'The code has 12 letters and digits.');
      return;
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Pair with ${widget.name}'),
      content: TextField(
        controller: _c,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(labelText: 'Pairing code', hintText: 'ABCD-EFGH-JKMN', errorText: _err),
        onSubmitted: (_) => _ok(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _ok, child: const Text('Pair')),
      ],
    );
  }
}
