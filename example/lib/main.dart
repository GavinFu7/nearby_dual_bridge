import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NearbyDualBridgeExampleApp());
}

class NearbyDualBridgeExampleApp extends StatelessWidget {
  const NearbyDualBridgeExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nearby Dual Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F6E56),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const BridgeHomePage(),
    );
  }
}

class BridgeHomePage extends StatefulWidget {
  const BridgeHomePage({super.key});

  @override
  State<BridgeHomePage> createState() => _BridgeHomePageState();
}

class _BridgeHomePageState extends State<BridgeHomePage> {
  final _bridge = DualBridgeManager();
  // Display name only; package prepends a hidden 8-char correlation code.
  final _deviceNameController = TextEditingController(text: 'MacHost');
  final _serviceUuidController = TextEditingController(
    text: BridgeConstants.defaultServiceUuid,
  );
  final _messageController = TextEditingController();
  final _logs = <String>[];
  final _scrollController = ScrollController();

  BridgeRole _role = BridgeRole.idle;
  BridgeConnectionState _connectionState = BridgeConnectionState.disconnected;
  TransportType? _activeTransport;
  ConnectionPreference _preference = ConnectionPreference.preferWifi;

  bool _hosting = false;
  bool _scanning = false;
  bool _busy = false;
  List<BridgeDevice> _devices = const [];
  BridgeDevice? _connectedDevice;
  StreamSubscription? _scanSub;
  StreamSubscription? _messageSub;
  StreamSubscription? _statusSub;
  int _peerCount = 0;

  @override
  void initState() {
    super.initState();
    _statusSub = _bridge.addStatusListener((status) {
      final reason = status.reason;
      final logLine = switch (reason) {
        'peer_connected' =>
          'Status: peer connected · peers=${status.peerCount} '
              '· ${status.activeTransport?.name ?? status.role.name}',
        'peer_disconnected' =>
          'Status: peer disconnected · peers=${status.peerCount} '
              '· connection=${status.connectionState.name}',
        'connected' =>
          'Status: connected via ${status.activeTransport?.name}',
        'disconnected' || 'connect_failed' || 'host_stopped' =>
          'Status: $reason',
        _ => null,
      };

      setState(() {
        _role = status.role;
        _connectionState = status.connectionState;
        _activeTransport = status.activeTransport;
        _peerCount = status.peerCount;
        if (status.role == BridgeRole.host) {
          _hosting = true;
        } else if (status.reason == 'host_stopped') {
          _hosting = false;
        }
        if (status.connectionState == BridgeConnectionState.disconnected ||
            status.connectionState == BridgeConnectionState.disconnecting) {
          _connectedDevice = null;
        }
        if (logLine != null) {
          final stamp = TimeOfDay.now().format(context);
          _logs.insert(0, '[$stamp] $logLine');
          if (_logs.length > 80) {
            _logs.removeLast();
          }
        }
      });
    });
    _messageSub = _bridge.onMessageReceived.listen((message) {
      _appendLog('← $message');
    });

    // Debug helpers:
    // flutter run -d macos --dart-define=AUTO_HOST=true
    // flutter run -d <iphone> --dart-define=AUTO_SCAN_WIFI=true
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      const autoHost = bool.fromEnvironment('AUTO_HOST');
      const autoScanWifi = bool.fromEnvironment('AUTO_SCAN_WIFI');
      if (autoHost) {
        await _toggleHost();
      }
      if (autoScanWifi) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!_hosting && !_scanning) {
          await _toggleScan(wifi: true, ble: false);
        }
      }
    });
  }

  @override
  void dispose() {
    unawaited(_scanSub?.cancel());
    unawaited(_messageSub?.cancel());
    unawaited(_statusSub?.cancel());
    unawaited(_bridge.dispose());
    _deviceNameController.dispose();
    _serviceUuidController.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String get _serviceUuid => _serviceUuidController.text.trim();

  String get _deviceName => _deviceNameController.text.trim();

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleHost() async {
    await _runBusy(() async {
      try {
        if (_hosting) {
          await _bridge.stopHost();
          setState(() => _hosting = false);
          _appendLog('Host stopped');
          return;
        }
        if (_deviceName.isEmpty) {
          _appendLog('Device name is required');
          return;
        }
        await _stopScan();
        final session = await _bridge.startHost(
          deviceName: _deviceName,
          serviceUuid: _serviceUuid,
        );
        setState(() => _hosting = true);
        _appendLog(
          'Host OK · Wi-Fi ${session.wifi.host}:${session.wifi.port}',
        );
        if (session.mdnsRegistered) {
          _appendLog('mDNS OK · ${BridgeConstants.mdnsServiceType}');
        } else {
          _appendLog('mDNS FAILED: ${session.mdnsError}');
          _appendLog(
            'WebSocket Host is still running — check Local Network permission '
            '(System Settings → Privacy & Security → Local Network)',
          );
        }
        if (session.bleAdvertising) {
          _appendLog('BLE advertising OK (Local Name = 8-char correlation code)');
        } else {
          _appendLog('BLE advertising FAILED: ${session.bleError}');
        }
      } catch (error) {
        _appendLog('Host error: $error');
      }
    });
  }

  Future<void> _toggleScan({bool wifi = true, bool ble = true}) async {
    await _runBusy(() async {
      try {
        if (_scanning) {
          await _stopScan();
          _appendLog('Scan stopped');
          return;
        }
        if (_hosting) {
          _appendLog('Stop Host before scanning as Client');
          return;
        }
        FocusScope.of(context).unfocus();
        setState(() {
          _scanning = true;
          _devices = const [];
        });
        final mode = [
          if (wifi) 'Wi-Fi',
          if (ble) 'BLE',
        ].join('+');
        var lastCount = -1;
        _scanSub = _bridge
            .scanHosts(serviceUuid: _serviceUuid, wifi: wifi, ble: ble)
            .listen(
          (devices) {
            setState(() => _devices = devices);
            if (devices.length != lastCount) {
              lastCount = devices.length;
              _appendLog('Found ${devices.length} host(s) [$mode]');
            }
          },
          onError: (Object error) => _appendLog('Scan error: $error'),
        );
        _appendLog(
          'Scanning $mode for $_serviceUuid … '
          '(allow Local Network for this app)',
        );
      } catch (error) {
        setState(() => _scanning = false);
        _appendLog('Scan error: $error');
      }
    });
  }

  Future<void> _stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _bridge.stopScan();
    if (mounted) {
      setState(() => _scanning = false);
    }
  }

  Future<void> _connect(BridgeDevice device) async {
    await _runBusy(() async {
      try {
        FocusScope.of(context).unfocus();
        await _stopScan();
        await _bridge.connect(device, preference: _preference);
        if (!mounted) return;
        setState(() {
          _connectedDevice = device;
          // Keep the connected Host visible after scan stops.
          if (!_devices.any((d) => d.id == device.id)) {
            _devices = [..._devices, device];
          }
        });
        _appendLog(
          'Connected to ${device.name} via ${_bridge.activeTransport?.name}',
        );
      } catch (error) {
        if (mounted) {
          setState(() => _connectedDevice = null);
        }
        _appendLog('Connect error: $error');
      }
    });
  }

  Future<void> _disconnect() async {
    await _runBusy(() async {
      try {
        await _bridge.disconnect();
        if (mounted) {
          setState(() => _connectedDevice = null);
        }
        _appendLog('Disconnected');
      } catch (error) {
        _appendLog('Disconnect error: $error');
      }
    });
  }

  bool _isConnectedTo(BridgeDevice device) {
    return _connectionState == BridgeConnectionState.connected &&
        _connectedDevice?.id == device.id;
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    final payload = <String, dynamic>{
      'type': 'chat',
      'text': text,
      'from': _deviceName.isEmpty ? 'anonymous' : _deviceName,
      'ts': DateTime.now().toIso8601String(),
    };
    try {
      await _bridge.sendMessage(payload);
      _appendLog('→ $payload');
      _messageController.clear();
    } catch (error) {
      _appendLog('Send error: $error');
    }
  }

  void _appendLog(String line) {
    if (!mounted) return;
    final stamp = TimeOfDay.now().format(context);
    setState(() {
      _logs.insert(0, '[$stamp] $line');
      if (_logs.length > 80) {
        _logs.removeLast();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final maxContentWidth = width >= 900 ? 720.0 : double.infinity;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      behavior: HitTestBehavior.deferToChild,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: const Text('Nearby Dual Bridge'),
          actions: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  _role.name.toUpperCase(),
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxContentWidth),
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _StatusBanner(
                  role: _role,
                  connectionState: _connectionState,
                  activeTransport: _activeTransport,
                  hosting: _hosting,
                  scanning: _scanning,
                  peerCount: _peerCount,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _deviceNameController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Device name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _serviceUuidController,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Service UUID',
                    border: OutlineInputBorder(),
                    helperText: 'Must match on Host and Client',
                  ),
                ),
                const SizedBox(height: 16),
                Text('Mode', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _toggleHost,
                      icon: Icon(_hosting ? Icons.stop : Icons.podcasts),
                      label: Text(_hosting ? 'Stop Host' : 'Start Host'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: (_busy || _hosting)
                          ? null
                          : () => _toggleScan(wifi: true, ble: true),
                      icon: Icon(_scanning ? Icons.search_off : Icons.search),
                      label: Text(_scanning ? 'Stop Scan' : 'Scan Both'),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_busy || _hosting || _scanning)
                          ? null
                          : () => _toggleScan(wifi: true, ble: false),
                      icon: const Icon(Icons.wifi_find),
                      label: const Text('Scan Wi-Fi only'),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_busy || _hosting || _scanning)
                          ? null
                          : () => _toggleScan(wifi: false, ble: true),
                      icon: const Icon(Icons.bluetooth_searching),
                      label: const Text('Scan BLE only'),
                    ),
                  ],
                ),
                if (_scanning) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy ? null : () => _toggleScan(),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Stop Scan'),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'Connection preference',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in ConnectionPreference.values)
                      ChoiceChip(
                        label: Text(_preferenceLabel(option)),
                        selected: _preference == option,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _preference = option),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Discovered hosts (${_devices.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (_devices.isEmpty)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.devices_other),
                      title: Text('No hosts yet'),
                      subtitle: Text(
                        'Start Host on another device, then Scan. '
                        'On iPad: Settings → Privacy → Local Network → enable this app.',
                      ),
                    ),
                  )
                else
                  ..._devices.map((device) {
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (device.supportsWifi)
                                  'Wi-Fi ${device.wifi!.host}:${device.wifi!.port}',
                                if (device.supportsBle)
                                  'BLE ${device.ble!.rssi ?? '-'} dBm',
                              ].join(' · '),
                            ),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerRight,
                              child: _isConnectedTo(device)
                                  ? FilledButton.tonalIcon(
                                      onPressed:
                                          _busy ? null : _disconnect,
                                      icon: const Icon(Icons.link_off),
                                      label: const Text('Disconnect'),
                                    )
                                  : FilledButton(
                                      onPressed: (_busy ||
                                              _connectionState ==
                                                  BridgeConnectionState
                                                      .connected ||
                                              _connectionState ==
                                                  BridgeConnectionState
                                                      .connecting)
                                          ? null
                                          : () => _connect(device),
                                      child: const Text('Connect'),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                const SizedBox(height: 20),
                Text('Messages', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        textInputAction: TextInputAction.send,
                        decoration: const InputDecoration(
                          hintText: 'JSON chat text…',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy ? null : _send,
                      child: const Text('Send'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Log', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _logs.isEmpty
                        ? const Text('No messages yet')
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final line in _logs.take(30))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: SelectableText(
                                    line,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _preferenceLabel(ConnectionPreference preference) {
    return switch (preference) {
      ConnectionPreference.preferWifi => 'Prefer Wi-Fi',
      ConnectionPreference.preferBle => 'Prefer BLE',
      ConnectionPreference.wifiOnly => 'Wi-Fi only',
      ConnectionPreference.bleOnly => 'BLE only',
    };
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.role,
    required this.connectionState,
    required this.activeTransport,
    required this.hosting,
    required this.scanning,
    required this.peerCount,
  });

  final BridgeRole role;
  final BridgeConnectionState connectionState;
  final TransportType? activeTransport;
  final bool hosting;
  final bool scanning;
  final int peerCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.primaryContainer,
            scheme.secondaryContainer.withValues(alpha: 0.9),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dual-role nearby bridge',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Role: ${role.name} · Connection: ${connectionState.name}'
            '${activeTransport == null ? '' : ' · ${activeTransport!.name}'}'
            ' · peers: $peerCount'
            '${hosting ? ' · advertising' : ''}'
            '${scanning ? ' · scanning' : ''}',
          ),
        ],
      ),
    );
  }
}
