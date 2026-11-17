import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge.dart';
import 'package:nsd/nsd.dart' show LogTopic, enableLogging;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Help diagnose mDNS discovery on device consoles / Xcode.
  enableLogging(LogTopic.errors);
  enableLogging(LogTopic.calls);
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
  // Keep <= 8 chars so macOS BLE Local Name is more likely to be advertised.
  final _deviceNameController = TextEditingController(text: 'MacHost');
  final _serviceUuidController = TextEditingController(
    text: BridgeConstants.defaultServiceUuid,
  );
  final _messageController = TextEditingController();
  final _logs = <String>[];

  BridgeRole _role = BridgeRole.idle;
  BridgeConnectionState _connectionState = BridgeConnectionState.disconnected;
  TransportType? _activeTransport;
  ConnectionPreference _preference = ConnectionPreference.preferWifi;

  bool _hosting = false;
  bool _scanning = false;
  List<BridgeDevice> _devices = const [];
  StreamSubscription? _scanSub;
  StreamSubscription? _messageSub;
  StreamSubscription? _roleSub;
  StreamSubscription? _connectionSub;

  @override
  void initState() {
    super.initState();
    _roleSub = _bridge.onRoleChanged.listen((role) {
      setState(() => _role = role);
    });
    _connectionSub = _bridge.onConnectionStateChanged.listen((state) {
      setState(() {
        _connectionState = state;
        _activeTransport = _bridge.activeTransport;
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
    unawaited(_roleSub?.cancel());
    unawaited(_connectionSub?.cancel());
    unawaited(_bridge.dispose());
    _deviceNameController.dispose();
    _serviceUuidController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  String get _serviceUuid => _serviceUuidController.text.trim();

  String get _deviceName => _deviceNameController.text.trim();

  Future<void> _toggleHost() async {
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
        'Host OK · Wi-Fi ${session.wifi.host}:${session.wifi.port} · '
        'mDNS ${BridgeConstants.mdnsServiceType}',
      );
      if (session.bleAdvertising) {
        _appendLog('BLE advertising OK (name may be truncated to 8 chars)');
      } else {
        _appendLog('BLE advertising FAILED: ${session.bleError}');
        _appendLog('Wi-Fi Host is still running — you can test mDNS first');
      }
    } catch (error) {
      _appendLog('Host error: $error');
    }
  }

  Future<void> _toggleScan({bool wifi = true, bool ble = true}) async {
    try {
      if (_scanning) {
        await _stopScan();
        return;
      }
      if (_hosting) {
        _appendLog('Stop Host before scanning as Client');
        return;
      }
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
        '(iPhone: allow Local Network for this app)',
      );
    } catch (error) {
      setState(() => _scanning = false);
      _appendLog('Scan error: $error');
    }
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
    try {
      await _stopScan();
      await _bridge.connect(device, preference: _preference);
      _appendLog(
        'Connected to ${device.name} via ${_bridge.activeTransport?.name}',
      );
    } catch (error) {
      _appendLog('Connect error: $error');
    }
  }

  Future<void> _disconnect() async {
    try {
      await _bridge.disconnect();
      _appendLog('Disconnected');
    } catch (error) {
      _appendLog('Disconnect error: $error');
    }
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
    // ignore: avoid_print
    print('[NDB] $line');
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Dual Bridge'),
        actions: [
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusBanner(
            role: _role,
            connectionState: _connectionState,
            activeTransport: _activeTransport,
            hosting: _hosting,
            scanning: _scanning,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _deviceNameController,
            decoration: const InputDecoration(
              labelText: 'Device name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _serviceUuidController,
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
                onPressed: _toggleHost,
                icon: Icon(_hosting ? Icons.stop : Icons.podcasts),
                label: Text(_hosting ? 'Stop Host' : 'Start Host'),
              ),
              FilledButton.tonalIcon(
                onPressed: _hosting
                    ? null
                    : () => _toggleScan(wifi: true, ble: true),
                icon: Icon(_scanning ? Icons.search_off : Icons.search),
                label: Text(_scanning ? 'Stop Scan' : 'Scan Both'),
              ),
              OutlinedButton.icon(
                onPressed: _hosting || _scanning
                    ? null
                    : () => _toggleScan(wifi: true, ble: false),
                icon: const Icon(Icons.wifi_find),
                label: const Text('Scan Wi-Fi only'),
              ),
              OutlinedButton.icon(
                onPressed: _hosting || _scanning
                    ? null
                    : () => _toggleScan(wifi: false, ble: true),
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Scan BLE only'),
              ),
              if (_connectionState == BridgeConnectionState.connected)
                OutlinedButton.icon(
                  onPressed: _disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Connection preference',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SegmentedButton<ConnectionPreference>(
            segments: const [
              ButtonSegment(
                value: ConnectionPreference.preferWifi,
                label: Text('Prefer Wi-Fi'),
                icon: Icon(Icons.wifi),
              ),
              ButtonSegment(
                value: ConnectionPreference.preferBle,
                label: Text('Prefer BLE'),
                icon: Icon(Icons.bluetooth),
              ),
              ButtonSegment(
                value: ConnectionPreference.wifiOnly,
                label: Text('Wi-Fi only'),
              ),
              ButtonSegment(
                value: ConnectionPreference.bleOnly,
                label: Text('BLE only'),
              ),
            ],
            selected: {_preference},
            onSelectionChanged: (value) {
              setState(() => _preference = value.first);
            },
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
                subtitle: Text('Start Host on another device, then Scan'),
              ),
            )
          else
            ..._devices.map(
              (device) => Card(
                child: ListTile(
                  title: Text(device.name),
                  subtitle: Text(
                    [
                      if (device.supportsWifi)
                        'Wi-Fi ${device.wifi!.host}:${device.wifi!.port}',
                      if (device.supportsBle)
                        'BLE ${device.ble!.rssi ?? '-'} dBm',
                    ].join(' · '),
                  ),
                  trailing: FilledButton(
                    onPressed: () => _connect(device),
                    child: const Text('Connect'),
                  ),
                  isThreeLine: true,
                ),
              ),
            ),
          const SizedBox(height: 20),
          Text('Messages', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  decoration: const InputDecoration(
                    hintText: 'JSON chat text…',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _send, child: const Text('Send')),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: Card(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      _logs[index],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.role,
    required this.connectionState,
    required this.activeTransport,
    required this.hosting,
    required this.scanning,
  });

  final BridgeRole role;
  final BridgeConnectionState connectionState;
  final TransportType? activeTransport;
  final bool hosting;
  final bool scanning;

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
            '${hosting ? ' · advertising' : ''}'
            '${scanning ? ' · scanning' : ''}',
          ),
        ],
      ),
    );
  }
}
