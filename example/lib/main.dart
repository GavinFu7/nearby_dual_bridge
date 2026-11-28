import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NearbyDualBridgeExampleApp());
}

/// 範例 App：示範 Nearby Dual Bridge 的 Host / Client 雙角色流程。
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

/// 主頁面：可切換 Host / Client、掃描、連線與收發訊息。
class BridgeHomePage extends StatefulWidget {
  const BridgeHomePage({super.key});

  @override
  State<BridgeHomePage> createState() => _BridgeHomePageState();
}

class _BridgeHomePageState extends State<BridgeHomePage> {
  /// 核心橋接管理器：負責 Host、掃描、連線與訊息傳輸。
  final _bridge = DualBridgeManager();

  /// 顯示用裝置名稱；套件會在內部再前置隱藏的 8 字元關聯碼。
  final _deviceNameController = TextEditingController(text: 'MacHost');

  /// Host / Client 必須使用相同的 Service UUID 才能互相發現。
  final _serviceUuidController = TextEditingController(
    text: BridgeConstants.defaultServiceUuid,
  );
  final _messageController = TextEditingController();
  final _logs = <String>[];
  final _scrollController = ScrollController();

  BridgeRole _role = BridgeRole.idle;
  BridgeConnectionState _connectionState = BridgeConnectionState.disconnected;
  TransportType? _activeTransport;

  /// 連線偏好：優先 Wi-Fi / BLE，或強制只用其中一種。
  ConnectionPreference _preference = ConnectionPreference.preferWifi;

  bool _hosting = false;
  bool _scanning = false;

  /// 防止按鈕連點造成重複啟動 Host / Scan / Connect。
  bool _busy = false;

  /// Client 掃描到的 Host 列表。
  List<BridgeDevice> _devices = const [];

  /// Host 端目前的對等端（含待核准連線）。
  List<BridgePeer> _hostPeers = const [];
  BridgeDevice? _connectedDevice;

  StreamSubscription? _scanSub;
  StreamSubscription? _messageSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _hostPeersSub;
  int _peerCount = 0;

  @override
  void initState() {
    super.initState();

    // 監聽橋接狀態變化（連線、斷線、Peer 核准等）。
    _statusSub = _bridge.addStatusListener((status) {
      final reason = status.reason;
      final logLine = switch (reason) {
        'peer_connection_request' =>
          'Status: connection request · peers=${status.peerCount}',
        'peer_connected' =>
          'Status: peer connected · peers=${status.peerCount} '
              '· ${status.activeTransport?.name ?? status.role.name}',
        'peer_rejected' => 'Status: peer rejected',
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
          _hostPeers = const [];
        }
        // Client 斷線後清掉目前連線裝置。
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

    // Host 端 Peer 列表更新（待核准 / 已連線）。
    _hostPeersSub = _bridge.onHostPeersChanged.listen((peers) {
      if (!mounted) return;
      setState(() => _hostPeers = peers);
    });

    // 收到對端訊息時寫入 Log。
    _messageSub = _bridge.onMessageReceived.listen((message) {
      _appendLog('← $message');
    });

    // 除錯用自動流程：
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
    unawaited(_hostPeersSub?.cancel());
    unawaited(_bridge.dispose());
    _deviceNameController.dispose();
    _serviceUuidController.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String get _serviceUuid => _serviceUuidController.text.trim();

  String get _deviceName => _deviceNameController.text.trim();

  /// 將非同步操作包一層 busy 鎖，避免重入。
  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 切換 Host：啟動時同時開 Wi-Fi WebSocket 與 BLE 廣播。
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
        // Host 與 Client 不可同時進行；先停掉掃描。
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

  /// 切換掃描；可分別啟用 Wi-Fi（mDNS）與 BLE。
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
            // 只在發現數量改變時寫 Log，避免刷屏。
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

  /// Client 連上指定 Host；會依 [_preference] 選擇傳輸方式。
  Future<void> _connect(BridgeDevice device) async {
    await _runBusy(() async {
      try {
        FocusScope.of(context).unfocus();
        await _stopScan();
        await _bridge.connect(device, preference: _preference);
        if (!mounted) return;
        setState(() {
          _connectedDevice = device;
          // 掃描停止後仍保留已連線 Host，方便 UI 顯示 Disconnect。
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

  /// Host 核准待連線 Peer，之後才能收發訊息。
  Future<void> _approvePeer(BridgePeer peer) async {
    try {
      await _bridge.approvePeer(peer.id);
      _appendLog('Approved ${peer.transport.name} ${peer.label ?? peer.id}');
    } catch (error) {
      _appendLog('Approve error: $error');
    }
  }

  Future<void> _rejectPeer(BridgePeer peer) async {
    try {
      await _bridge.rejectPeer(peer.id);
      _appendLog('Rejected ${peer.transport.name} ${peer.label ?? peer.id}');
    } catch (error) {
      _appendLog('Reject error: $error');
    }
  }

  /// Host 主動踢除已連線 Peer。
  Future<void> _kickPeer(BridgePeer peer) async {
    try {
      await _bridge.disconnectPeer(peer.id);
      _appendLog('Kicked ${peer.transport.name} ${peer.label ?? peer.id}');
    } catch (error) {
      _appendLog('Kick error: $error');
    }
  }

  bool _isConnectedTo(BridgeDevice device) {
    return _connectionState == BridgeConnectionState.connected &&
        _connectedDevice?.id == device.id;
  }

  /// 送出簡單聊天 JSON；實際傳輸走目前啟用的 Wi-Fi 或 BLE。
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
    // 寬螢幕限制內容寬度，避免輸入區過寬。
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
                // 狀態總覽：角色、連線狀態、傳輸方式、Peer 數。
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
                // Host / 掃描按鈕區。
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
                // Client 連線偏好（Prefer Wi-Fi / Prefer BLE / Only）。
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
                // Host 端 Peer 管理：Approve / Reject / Kick。
                if (_hosting) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Host peers (${_hostPeers.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_hostPeers.isEmpty)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.person_off_outlined),
                        title: Text('No clients yet'),
                        subtitle: Text(
                          'Incoming connections need Approve before messaging.',
                        ),
                      ),
                    )
                  else
                    ..._hostPeers.map((peer) {
                      final pending = peer.isPending;
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            peer.transport == TransportType.wifi
                                ? Icons.wifi
                                : Icons.bluetooth,
                          ),
                          title: Text(peer.label ?? peer.id),
                          subtitle: Text(
                            '${peer.transport.name} · ${peer.state.name}',
                          ),
                          trailing: pending
                              ? Wrap(
                                  spacing: 4,
                                  children: [
                                    IconButton(
                                      tooltip: 'Reject',
                                      onPressed: _busy
                                          ? null
                                          : () => _rejectPeer(peer),
                                      icon: const Icon(Icons.close),
                                    ),
                                    IconButton.filled(
                                      tooltip: 'Approve',
                                      onPressed: _busy
                                          ? null
                                          : () => _approvePeer(peer),
                                      icon: const Icon(Icons.check),
                                    ),
                                  ],
                                )
                              : IconButton(
                                  tooltip: 'Disconnect',
                                  onPressed:
                                      _busy ? null : () => _kickPeer(peer),
                                  icon: const Icon(Icons.link_off),
                                ),
                        ),
                      );
                    }),
                ],
                const SizedBox(height: 20),
                // Client 掃描結果與連線按鈕。
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
                // 訊息收發區。
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
                // 事件與訊息 Log（最新在上）。
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

/// 頂部狀態橫幅：顯示目前角色、連線與廣播／掃描狀態。
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
