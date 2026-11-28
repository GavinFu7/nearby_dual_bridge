import 'dart:async';

import 'ble/ble_transport_impl.dart';
import 'bridge_constants.dart';
import 'interfaces/ble_transport.dart';
import 'interfaces/bridge_permissions.dart';
import 'interfaces/wifi_transport.dart';
import 'models/bridge_connection_state.dart';
import 'models/bridge_device.dart';
import 'models/bridge_peer.dart';
import 'models/bridge_peer_event.dart';
import 'models/bridge_role.dart';
import 'models/bridge_status.dart';
import 'models/connection_preference.dart';
import 'models/host_session.dart';
import 'models/transport_type.dart';
import 'permissions/bridge_permissions_impl.dart';
import 'scan_merge.dart';
import 'wifi/wifi_transport_impl.dart';

/// Unified Host/Client API over Wi-Fi (mDNS + WebSocket) and BLE.
class DualBridgeManager {
  DualBridgeManager({
    WifiTransport? wifiTransport,
    BleTransport? bleTransport,
    BridgePermissions? permissions,
  })  : _wifi = wifiTransport ?? WifiTransportImpl(),
        _ble = bleTransport ?? BleTransportImpl(),
        _permissions = permissions ?? BridgePermissionsImpl() {
    _wifiMessageSub = _wifi.onMessageReceived.listen(_messageController.add);
    _bleMessageSub = _ble.onMessageReceived.listen(_messageController.add);
    _wifiPeerSub = _wifi.onPeerConnectionChanged.listen(_onWifiPeerEvent);
    _blePeerSub = _ble.onPeerConnectionChanged.listen(_onBlePeerEvent);
  }

  final WifiTransport _wifi;
  final BleTransport _ble;
  final BridgePermissions _permissions;

  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionStateController =
      StreamController<BridgeConnectionState>.broadcast();
  final _roleController = StreamController<BridgeRole>.broadcast();
  final _statusController = StreamController<BridgeStatus>.broadcast();
  final _hostPeersController =
      StreamController<List<BridgePeer>>.broadcast();
  final _peerEventController =
      StreamController<BridgePeerEvent>.broadcast();

  StreamSubscription? _wifiMessageSub;
  StreamSubscription? _bleMessageSub;
  StreamSubscription? _wifiPeerSub;
  StreamSubscription? _blePeerSub;
  StreamSubscription? _wifiScanSub;
  StreamSubscription? _bleScanSub;
  StreamController<List<BridgeDevice>>? _scanController;

  BridgeRole _role = BridgeRole.idle;
  BridgeConnectionState _connectionState = BridgeConnectionState.disconnected;
  TransportType? _activeTransport;
  int _wifiPeers = 0;
  int _blePeers = 0;
  bool _localDisconnect = false;
  final _hostPeersById = <String, BridgePeer>{};

  BridgeRole get role => _role;

  BridgeConnectionState get connectionState => _connectionState;

  /// Transport used by the active Client connection, if any.
  TransportType? get activeTransport => _activeTransport;

  /// Current status snapshot.
  BridgeStatus get status => BridgeStatus(
        role: _role,
        connectionState: _connectionState,
        activeTransport: _activeTransport,
        peerCount: _peerCount,
      );

  Stream<BridgeRole> get onRoleChanged => _roleController.stream;

  Stream<BridgeConnectionState> get onConnectionStateChanged =>
      _connectionStateController.stream;

  /// Fires on role / connection / peer-count changes (including unexpected drops).
  Stream<BridgeStatus> get onStatusChanged => _statusController.stream;

  /// Unified inbound JSON messages from the peer (Host↔Client).
  Stream<Map<String, dynamic>> get onMessageReceived =>
      _messageController.stream;

  /// Host-side peers (pending approval + connected) across Wi-Fi and BLE.
  List<BridgePeer> get hostPeers =>
      _hostPeersById.values.toList(growable: false);

  /// Emits whenever [hostPeers] changes.
  Stream<List<BridgePeer>> get onHostPeersChanged =>
      _hostPeersController.stream;

  /// Detailed Host/Client peer lifecycle events (includes [BridgePeer]).
  Stream<BridgePeerEvent> get onPeerEvent => _peerEventController.stream;

  /// Convenience listener; emits the current [status] immediately, then updates.
  StreamSubscription<BridgeStatus> addStatusListener(
    void Function(BridgeStatus status) listener,
  ) {
    scheduleMicrotask(() {
      if (!_statusController.isClosed) {
        listener(status);
      }
    });
    return _statusController.stream.listen(listener);
  }

  /// Start Host mode: local WebSocket server + mDNS + BLE Peripheral advertising.
  ///
  /// [deviceName] is the display name. An 8-char correlation code is prepended
  /// automatically for Wi-Fi + BLE; Clients strip it before showing the name and
  /// use it to merge dual-transport sightings of the same Host.
  ///
  /// Wi-Fi WebSocket Host is required. mDNS register and BLE advertise failures
  /// are reported in [HostSession.mdnsError] / [HostSession.bleError] without
  /// tearing down the WebSocket server.
  ///
  /// When [requireConnectionApproval] is true (default), incoming Clients emit
  /// [BridgePeerEventType.connectionRequest] until [approvePeer] / [rejectPeer].
  Future<HostSession> startHost({
    required String deviceName,
    required String serviceUuid,
    bool requireConnectionApproval = true,
  }) async {
    if (_role == BridgeRole.client &&
        _connectionState != BridgeConnectionState.disconnected) {
      await disconnect();
    }
    await stopScan();
    _clearHostPeers();

    final granted = await _permissions.ensureHostPermissions();
    if (!granted) {
      throw StateError('Host permissions were not granted');
    }

    final wireName = BridgeConstants.encodeDeviceName(
      correlationCode: BridgeConstants.generateCorrelationCode(),
      displayName: deviceName,
    );

    final wifi = await _wifi.startHost(
      deviceName: wireName,
      serviceUuid: serviceUuid,
      requireConnectionApproval: requireConnectionApproval,
    );

    Object? bleError;
    var bleAdvertising = false;
    try {
      await _ble.startHost(
        deviceName: wireName,
        serviceUuid: serviceUuid,
        requireConnectionApproval: requireConnectionApproval,
      );
      bleAdvertising = true;
    } catch (error) {
      bleError = error;
    }

    _setRole(BridgeRole.host, reason: 'host_started');
    return HostSession(
      wifi: wifi.endpoint,
      mdnsRegistered: wifi.mdnsRegistered,
      mdnsError: wifi.mdnsError,
      bleAdvertising: bleAdvertising,
      bleError: bleError,
    );
  }

  /// Approve a pending Host peer (Wi-Fi or BLE).
  Future<void> approvePeer(String peerId) async {
    _ensureHost();
    if (peerId.startsWith('wifi:')) {
      await _wifi.approvePeer(peerId);
    } else if (peerId.startsWith('ble:')) {
      await _ble.approvePeer(peerId);
    } else {
      throw StateError('Unknown peer id: $peerId');
    }
  }

  /// Reject a pending Host peer and drop the link when possible.
  Future<void> rejectPeer(String peerId) async {
    _ensureHost();
    if (peerId.startsWith('wifi:')) {
      await _wifi.rejectPeer(peerId);
    } else if (peerId.startsWith('ble:')) {
      await _ble.rejectPeer(peerId);
    } else {
      throw StateError('Unknown peer id: $peerId');
    }
  }

  /// Disconnect / kick a Host peer by id (pending or connected).
  Future<void> disconnectPeer(String peerId) async {
    _ensureHost();
    if (peerId.startsWith('wifi:')) {
      await _wifi.disconnectPeer(peerId);
    } else if (peerId.startsWith('ble:')) {
      await _ble.disconnectPeer(peerId);
    } else {
      throw StateError('Unknown peer id: $peerId');
    }
  }

  void _ensureHost() {
    if (_role != BridgeRole.host) {
      throw StateError('Not in Host mode');
    }
  }

  /// Stop Host mode and tear down all advertisements / servers.
  Future<void> stopHost() async {
    _localDisconnect = true;
    Object? bleError;
    Object? wifiError;
    try {
      try {
        await _ble.stopHost();
      } catch (error) {
        bleError = error;
      }
      try {
        await _wifi.stopHost();
      } catch (error) {
        wifiError = error;
      }
    } finally {
      _localDisconnect = false;
    }
    _wifiPeers = 0;
    _blePeers = 0;
    _clearHostPeers();
    if (_role == BridgeRole.host) {
      _setRole(BridgeRole.idle, reason: 'host_stopped');
    }
    _emitStatus(reason: 'host_stopped');
    if (bleError != null && wifiError != null) {
      throw StateError('stopHost failed (ble: $bleError, wifi: $wifiError)');
    }
  }

  /// Scan for Hosts via mDNS and/or BLE Central, filtered by [serviceUuid].
  ///
  /// Emits merged [BridgeDevice] lists (same Host's Wi-Fi + BLE endpoints combined).
  ///
  /// Transport errors are isolated: a BLE failure will not stop Wi-Fi results
  /// (and vice versa). Use [wifi]/[ble] to test one path at a time.
  Stream<List<BridgeDevice>> scanHosts({
    required String serviceUuid,
    bool wifi = true,
    bool ble = true,
  }) {
    if (!wifi && !ble) {
      return Stream.error(
        ArgumentError('scanHosts requires wifi and/or ble to be true'),
      );
    }

    // Keep per-transport snapshots so continuous scan updates replace stale
    // rows (e.g. BLE name resolve) instead of accumulating old ids.
    var wifiDevices = <BridgeDevice>[];
    var bleDevices = <BridgeDevice>[];
    final seenWithWifiKeys = <String>{};
    final suppressBleOnlyKeys = <String>{};
    late final StreamController<List<BridgeDevice>> controller;

    void emitMerged() {
      if (controller.isClosed) return;
      updateWifiLossBleSuppression(
        seenWithWifiKeys: seenWithWifiKeys,
        suppressBleOnlyKeys: suppressBleOnlyKeys,
        wifiKeys: wifiDevices.map(scanMergeKey),
        bleKeys: bleDevices.map(scanMergeKey),
      );
      controller.add(
        mergeWifiBleScanSnapshots(
          wifiDevices: wifiDevices,
          bleDevices: bleDevices,
          suppressBleOnlyKeys: suppressBleOnlyKeys,
        ),
      );
    }

    // Per-transport scan errors are swallowed so the other transport can
    // keep emitting results.
    void ignoreTransportError(Object error, StackTrace stackTrace) {}

    controller = StreamController<List<BridgeDevice>>(
      onListen: () async {
        await _stopTransportScans();
        wifiDevices = [];
        bleDevices = [];
        seenWithWifiKeys.clear();
        suppressBleOnlyKeys.clear();

        final granted = await _permissions.ensureScanPermissions();
        if (!granted) {
          if (!controller.isClosed) {
            controller.addError(
              StateError('Scan permissions were not granted'),
            );
            await controller.close();
          }
          return;
        }

        if (_role != BridgeRole.host) {
          _setRole(BridgeRole.client, reason: 'scan_started');
        }

        var started = 0;
        Object? lastStartError;

        if (wifi) {
          try {
            _wifiScanSub = _wifi.scanHosts(serviceUuid: serviceUuid).listen(
              (batch) {
                wifiDevices = batch;
                if (ble) {
                  _ble.updateWifiMatchedCorrelationCodes({
                    for (final device in batch)
                      if (device.correlationCode != null &&
                          device.correlationCode!.trim().isNotEmpty)
                        device.correlationCode!.trim().toLowerCase(),
                  });
                }
                emitMerged();
              },
              onError: ignoreTransportError,
            );
            started++;
          } catch (error) {
            lastStartError = error;
          }
        }

        if (ble) {
          try {
            if (!wifi) {
              _ble.updateWifiMatchedCorrelationCodes(const {});
            }
            _bleScanSub = _ble.scanHosts(serviceUuid: serviceUuid).listen(
              (batch) {
                bleDevices = batch;
                emitMerged();
              },
              onError: ignoreTransportError,
            );
            started++;
          } catch (error) {
            lastStartError = error;
          }
        }

        if (started == 0 && !controller.isClosed) {
          controller.addError(
            StateError(
              'Unable to start any scan transport: ${lastStartError ?? 'unknown'}',
            ),
          );
          await controller.close();
        }
      },
      onCancel: _stopTransportScans,
    );

    final previous = _scanController;
    _scanController = controller;
    if (previous != null && !previous.isClosed) {
      unawaited(previous.close());
    }
    return controller.stream;
  }

  Future<void> _stopTransportScans() async {
    await _wifiScanSub?.cancel();
    await _bleScanSub?.cancel();
    _wifiScanSub = null;
    _bleScanSub = null;
    _ble.updateWifiMatchedCorrelationCodes(const {});
    await _wifi.stopScan();
    await _ble.stopScan();
  }

  Future<void> stopScan() async {
    await _stopTransportScans();
    final controller = _scanController;
    _scanController = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  /// Connect to [device]. Default prefers Wi-Fi, falls back to BLE.
  Future<void> connect(
    BridgeDevice device, {
    ConnectionPreference preference = ConnectionPreference.preferWifi,
  }) async {
    if (_role == BridgeRole.host) {
      throw StateError('Stop Host mode before connecting as Client');
    }

    await stopScan();
    _setConnectionState(
      BridgeConnectionState.connecting,
      reason: 'connecting',
    );
    _setRole(BridgeRole.client, reason: 'connecting');

    try {
      final order = _transportOrder(device, preference);
      Object? lastError;
      for (final transport in order) {
        try {
          if (transport == TransportType.wifi) {
            final wifi = device.wifi;
            if (wifi == null) continue;
            await _wifi.connect(wifi);
            _activeTransport = TransportType.wifi;
          } else {
            final ble = device.ble;
            if (ble == null) continue;
            await _ble.connect(ble, serviceUuid: device.serviceUuid);
            _activeTransport = TransportType.ble;
          }
          _setConnectionState(
            BridgeConnectionState.connected,
            reason: 'connected',
          );
          return;
        } catch (error) {
          lastError = error;
        }
      }
      throw StateError(
        'Unable to connect to ${device.name}: ${lastError ?? 'no transport'}',
      );
    } catch (error) {
      _activeTransport = null;
      _setConnectionState(
        BridgeConnectionState.disconnected,
        reason: 'connect_failed',
      );
      rethrow;
    }
  }

  /// Disconnect the active Client session.
  Future<void> disconnect() async {
    _localDisconnect = true;
    _setConnectionState(
      BridgeConnectionState.disconnecting,
      reason: 'disconnecting',
    );
    try {
      await _wifi.disconnect();
      await _ble.disconnect();
    } finally {
      _localDisconnect = false;
    }
    _activeTransport = null;
    _wifiPeers = 0;
    _blePeers = 0;
    _setConnectionState(
      BridgeConnectionState.disconnected,
      reason: 'disconnected',
    );
    if (_role == BridgeRole.client) {
      _setRole(BridgeRole.idle, reason: 'disconnected');
    }
  }

  /// Send a JSON map to the connected peer over the active transport.
  ///
  /// In Host mode, fans out over Wi-Fi sockets and BLE notifies.
  Future<void> sendMessage(Map<String, dynamic> data) async {
    if (_role == BridgeRole.host) {
      Object? wifiError;
      Object? bleError;
      try {
        await _wifi.sendMessage(data);
      } catch (error) {
        wifiError = error;
      }
      try {
        await _ble.sendMessage(data);
      } catch (error) {
        bleError = error;
      }
      if (wifiError != null && bleError != null) {
        throw StateError(
          'No Host peers available (wifi: $wifiError, ble: $bleError)',
        );
      }
      return;
    }

    switch (_activeTransport) {
      case TransportType.wifi:
        await _wifi.sendMessage(data);
      case TransportType.ble:
        await _ble.sendMessage(data);
      case null:
        throw StateError('Not connected');
    }
  }

  Future<void> dispose() async {
    await stopScan();
    await stopHost();
    await disconnect();
    await _wifiMessageSub?.cancel();
    await _bleMessageSub?.cancel();
    await _wifiPeerSub?.cancel();
    await _blePeerSub?.cancel();
    await _wifi.dispose();
    await _ble.dispose();
    await _messageController.close();
    await _connectionStateController.close();
    await _roleController.close();
    await _statusController.close();
    await _hostPeersController.close();
    await _peerEventController.close();
  }

  void _onWifiPeerEvent(BridgePeerEvent event) {
    _wifiPeers = event.peerCount;
    _trackHostPeer(event);
    _handlePeerEvent(event);
  }

  void _onBlePeerEvent(BridgePeerEvent event) {
    _blePeers = event.peerCount;
    _trackHostPeer(event);
    _handlePeerEvent(event);
  }

  void _trackHostPeer(BridgePeerEvent event) {
    final peer = event.peer;
    if (peer != null) {
      switch (event.type) {
        case BridgePeerEventType.connectionRequest:
        case BridgePeerEventType.connected:
          _hostPeersById[peer.id] = peer;
        case BridgePeerEventType.rejected:
        case BridgePeerEventType.disconnected:
          _hostPeersById.remove(peer.id);
      }
      _emitHostPeers();
    }
    if (!_peerEventController.isClosed) {
      _peerEventController.add(event);
    }
  }

  void _clearHostPeers() {
    if (_hostPeersById.isEmpty) return;
    _hostPeersById.clear();
    _emitHostPeers();
  }

  void _emitHostPeers() {
    if (_hostPeersController.isClosed) return;
    _hostPeersController.add(hostPeers);
  }

  void _handlePeerEvent(BridgePeerEvent event) {
    final reason = switch (event.type) {
      BridgePeerEventType.connectionRequest => 'peer_connection_request',
      BridgePeerEventType.connected => 'peer_connected',
      BridgePeerEventType.rejected => 'peer_rejected',
      BridgePeerEventType.disconnected => 'peer_disconnected',
    };

    if (_localDisconnect) {
      _emitStatus(reason: reason);
      return;
    }

    if (_role == BridgeRole.client &&
        _activeTransport == event.transport &&
        event.type == BridgePeerEventType.disconnected) {
      _activeTransport = null;
      _setConnectionState(
        BridgeConnectionState.disconnected,
        reason: 'peer_disconnected',
      );
      _setRole(BridgeRole.idle, reason: 'peer_disconnected');
      return;
    }

    _emitStatus(reason: reason);
  }

  int get _peerCount {
    if (_role == BridgeRole.client &&
        _connectionState == BridgeConnectionState.connected) {
      return 1;
    }
    return _wifiPeers + _blePeers;
  }

  List<TransportType> _transportOrder(
    BridgeDevice device,
    ConnectionPreference preference,
  ) {
    switch (preference) {
      case ConnectionPreference.preferWifi:
        return [
          if (device.supportsWifi) TransportType.wifi,
          if (device.supportsBle) TransportType.ble,
        ];
      case ConnectionPreference.preferBle:
        return [
          if (device.supportsBle) TransportType.ble,
          if (device.supportsWifi) TransportType.wifi,
        ];
      case ConnectionPreference.wifiOnly:
        return [if (device.supportsWifi) TransportType.wifi];
      case ConnectionPreference.bleOnly:
        return [if (device.supportsBle) TransportType.ble];
    }
  }

  void _setRole(BridgeRole role, {String? reason}) {
    if (_role == role) {
      if (reason != null) _emitStatus(reason: reason);
      return;
    }
    _role = role;
    if (!_roleController.isClosed) {
      _roleController.add(role);
    }
    _emitStatus(reason: reason);
  }

  void _setConnectionState(
    BridgeConnectionState state, {
    String? reason,
  }) {
    if (_connectionState == state) {
      if (reason != null) _emitStatus(reason: reason);
      return;
    }
    _connectionState = state;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state);
    }
    _emitStatus(reason: reason);
  }

  void _emitStatus({String? reason}) {
    if (_statusController.isClosed) return;
    _statusController.add(
      BridgeStatus(
        role: _role,
        connectionState: _connectionState,
        activeTransport: _activeTransport,
        peerCount: _peerCount,
        reason: reason,
      ),
    );
  }
}
