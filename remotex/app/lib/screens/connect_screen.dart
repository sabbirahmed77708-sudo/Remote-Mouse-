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
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Connect to a PC'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.wifi_find_rounded), text: 'Wi-Fi'),
            Tab(icon: Icon(Icons.qr_code_scanner_rounded), text: 'QR code'),
            Tab(icon: Icon(Icons.keyboard_rounded), text: 'Manual'),
            Tab(icon: Icon(Icons.bluetooth_rounded), text: 'Bluetooth'),
          ]),
        ),
        body: const TabBarView(
          physics: NeverScrollableScrollPhysics(),
          children: [_NearbyTab(), _QrTab(), _ManualTab(), _BluetoothTab()],
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
    // Not paired yet: ask the PC to show "Allow?" - no code to type.
    final navigator = Navigator.of(context);
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _AllowDialog(pcName: d.name),
    ).then((_) => dialogOpen = false);
    final ok = await scope.conn.pairByAllow(host: d.host, port: d.port);
    if (dialogOpen && mounted) navigator.pop(); // closes the dialog
    if (!mounted) return;
    if (ok) {
      scope.app.haptic(strong: true);
      navigator.pop(true);
    } else if (scope.conn.state == LinkState.failed) {
      showSnack(context, scope.conn.error ?? 'Could not connect', error: true);
    }
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
                        subtitle: Text('${d.host}  -  ${scope.app.pcById(d.id) != null ? 'paired' : 'tap to connect'}'),
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
                errorBuilder: (context, error, _) => Center(
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

class _AllowDialog extends StatelessWidget {
  const _AllowDialog({required this.pcName});
  final String pcName;

  @override
  Widget build(BuildContext context) {
    final conn = AppScope.of(context).conn;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: conn,
      builder: (context, _) {
        final sas = conn.waitingSas;
        return AlertDialog(
          title: Text('Connecting to $pcName'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sas == null) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 14),
                const Text('Contacting the PC...'),
              ] else ...[
                const Text('On your PC, press Allow. Check that it shows this number:'),
                const SizedBox(height: 14),
                Center(
                  child: Text(
                    '${sas.substring(0, 3)} ${sas.substring(3)}',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: cs.primary),
                  ),
                ),
                const SizedBox(height: 10),
                Text('If the numbers are different, press Deny on the PC.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ],
          ),
          actions: [TextButton(onPressed: conn.disconnect, child: const Text('Cancel'))],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

/// Bluetooth mode: the phone pretends to be a Bluetooth mouse + keyboard. Nothing to install on the PC.
class _BluetoothTab extends StatefulWidget {
  const _BluetoothTab();

  @override
  State<_BluetoothTab> createState() => _BluetoothTabState();
}

class _BluetoothTabState extends State<_BluetoothTab> with WidgetsBindingObserver {
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) AppScope.read(context).conn.bt.refreshDevices();
  }

  Future<void> _start() async {
    final bt = AppScope.read(context).conn.bt;
    await bt.init();
    if (mounted) setState(() => _starting = false);
  }

  Future<void> _connect(String address) async {
    final scope = AppScope.read(context);
    final navigator = Navigator.of(context);
    final started = await scope.conn.bt.connect(address);
    if (!mounted) return;
    if (!started) {
      showSnack(context, 'Could not start the connection. Is Bluetooth on the PC turned on?', error: true);
      return;
    }
    // the link state arrives from Android; wait briefly for it
    for (var i = 0; i < 40 && !scope.conn.bt.connected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
    }
    if (scope.conn.bt.connected) {
      scope.app.haptic(strong: true);
      navigator.pop(true);
    } else if (mounted) {
      showSnack(context, 'The PC did not answer. Pair the phone in Windows first, then try again.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final bt = scope.conn.bt;
    return ListenableBuilder(
      listenable: bt,
      builder: (context, _) {
        if (_starting) return const Center(child: CircularProgressIndicator());
        if (!bt.supported) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bluetooth_disabled_rounded, size: 48, color: cs.outline),
                const SizedBox(height: 14),
                Text(bt.problem ?? 'Bluetooth mouse mode is not available on this phone.', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: () {
                    setState(() => _starting = true);
                    _start();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
                const SizedBox(height: 12),
                Text('You can still use the Wi-Fi tabs.', style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Use your phone as a Bluetooth mouse and keyboard. Nothing needs to be installed on the PC.',
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            const SectionTitle('1. Pair once in Windows'),
            Text(
              'Press the button, then on the PC open Settings > Bluetooth & devices > Add device > Bluetooth '
              'and pick this phone. Confirm the code on both screens.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: bt.makeDiscoverable,
              icon: const Icon(Icons.visibility_rounded),
              label: const Text('Make this phone visible (2 min)'),
            ),
            const SectionTitle('2. Connect'),
            if (bt.bonded.isEmpty)
              Text('No paired devices yet. Finish step 1, then come back here.', style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
            else
              for (final d in bt.bonded)
                Card(
                  elevation: 0,
                  color: cs.surfaceContainerHigh,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                  child: ListTile(
                    leading: Icon(bt.connectedAddress == d.address ? Icons.bluetooth_connected_rounded : Icons.bluetooth_rounded),
                    title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(bt.connectedAddress == d.address ? 'connected' : 'tap to connect'),
                    onTap: bt.connectedAddress == d.address ? null : () => _connect(d.address),
                  ),
                ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(onPressed: bt.refreshDevices, icon: const Icon(Icons.refresh_rounded), label: const Text('Refresh')),
                TextButton.icon(onPressed: bt.openSettings, icon: const Icon(Icons.settings_bluetooth_rounded), label: const Text('Phone Bluetooth settings')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Bluetooth mode types US-keyboard characters only. Wi-Fi mode supports every language.',
              style: text.bodySmall?.copyWith(color: cs.outline),
            ),
          ],
        );
      },
    );
  }
}
