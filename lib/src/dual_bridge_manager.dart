import 'dart:async';

import 'ble/ble_transport_impl.dart';
import 'interfaces/ble_transport.dart';
import 'interfaces/bridge_permissions.dart';
import 'interfaces/wifi_transport.dart';
import 'models/bridge_connection_state.dart';
import 'models/bridge_device.dart';
import 'models/bridge_peer_event.dart';
import 'models/bridge_role.dart';
import 'models/bridge_status.dart';
import 'models/connection_preference.dart';
import 'models/host_session.dart';
import 'models/transport_type.dart';
import 'permissions/bridge_permissions_impl.dart';
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
  /// Wi-Fi Host is required. BLE advertise failures are reported in
  /// [HostSession.bleError] without tearing down Wi-Fi, so you can still test
  /// mDNS / WebSocket while debugging Bluetooth.
  Future<HostSession> startHost({
    required String deviceName,
    required String serviceUuid,
  }) async {
    if (_role == BridgeRole.client &&
        _connectionState != BridgeConnectionState.disconnected) {
      await disconnect();
    }
    await stopScan();

    final granted = await _permissions.ensureHostPermissions();
    if (!granted) {
      throw StateError('Host permissions were not granted');
    }

    final wifi = await _wifi.startHost(
      deviceName: deviceName,
      serviceUuid: serviceUuid,
    );

    Object? bleError;
    var bleAdvertising = false;
    try {
      await _ble.startHost(
        deviceName: deviceName,
        serviceUuid: serviceUuid,
      );
      bleAdvertising = true;
    } catch (error) {
      bleError = error;
    }

    _setRole(BridgeRole.host, reason: 'host_started');
    return HostSession(
      wifi: wifi,
      bleAdvertising: bleAdvertising,
      bleError: bleError,
    );
  }

  /// Stop Host mode and tear down all advertisements / servers.
  Future<void> stopHost() async {
    _localDisconnect = true;
    try {
      await _ble.stopHost();
      await _wifi.stopHost();
    } finally {
      _localDisconnect = false;
    }
    _wifiPeers = 0;
    _blePeers = 0;
    if (_role == BridgeRole.host) {
      _setRole(BridgeRole.idle, reason: 'host_stopped');
    }
    _emitStatus(reason: 'host_stopped');
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

    final merged = <String, BridgeDevice>{};
    late final StreamController<List<BridgeDevice>> controller;

    void emit() {
      if (!controller.isClosed) {
        controller.add(merged.values.toList(growable: false));
      }
    }

    void ingest(List<BridgeDevice> batch) {
      for (final device in batch) {
        final existing = merged[device.id];
        merged[device.id] =
            existing == null ? device : existing.merge(device);
      }
      emit();
    }

    // Per-transport scan errors are swallowed so the other transport can
    // keep emitting results.
    void ignoreTransportError(Object error, StackTrace stackTrace) {}

    controller = StreamController<List<BridgeDevice>>(
      onListen: () async {
        await _stopTransportScans();

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
              ingest,
              onError: ignoreTransportError,
            );
            started++;
          } catch (error) {
            lastStartError = error;
          }
        }

        if (ble) {
          try {
            _bleScanSub = _ble.scanHosts(serviceUuid: serviceUuid).listen(
              ingest,
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
  }

  void _onWifiPeerEvent(BridgePeerEvent event) {
    _wifiPeers = event.peerCount;
    _handlePeerEvent(event);
  }

  void _onBlePeerEvent(BridgePeerEvent event) {
    _blePeers = event.peerCount;
    _handlePeerEvent(event);
  }

  void _handlePeerEvent(BridgePeerEvent event) {
    if (_localDisconnect) {
      _emitStatus(
        reason: event.type == BridgePeerEventType.connected
            ? 'peer_connected'
            : 'peer_disconnected',
      );
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

    _emitStatus(
      reason: event.type == BridgePeerEventType.connected
          ? 'peer_connected'
          : 'peer_disconnected',
    );
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
