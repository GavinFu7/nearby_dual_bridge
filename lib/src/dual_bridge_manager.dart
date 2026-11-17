import 'dart:async';

import 'ble/ble_transport_impl.dart';
import 'interfaces/ble_transport.dart';
import 'interfaces/bridge_permissions.dart';
import 'interfaces/wifi_transport.dart';
import 'models/bridge_connection_state.dart';
import 'models/bridge_device.dart';
import 'models/bridge_role.dart';
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
  }

  final WifiTransport _wifi;
  final BleTransport _ble;
  final BridgePermissions _permissions;

  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionStateController =
      StreamController<BridgeConnectionState>.broadcast();
  final _roleController = StreamController<BridgeRole>.broadcast();

  StreamSubscription? _wifiMessageSub;
  StreamSubscription? _bleMessageSub;
  StreamSubscription? _wifiScanSub;
  StreamSubscription? _bleScanSub;
  StreamController<List<BridgeDevice>>? _scanController;

  BridgeRole _role = BridgeRole.idle;
  BridgeConnectionState _connectionState = BridgeConnectionState.disconnected;
  TransportType? _activeTransport;

  BridgeRole get role => _role;

  BridgeConnectionState get connectionState => _connectionState;

  /// Transport used by the active Client connection, if any.
  TransportType? get activeTransport => _activeTransport;

  Stream<BridgeRole> get onRoleChanged => _roleController.stream;

  Stream<BridgeConnectionState> get onConnectionStateChanged =>
      _connectionStateController.stream;

  /// Unified inbound JSON messages from the peer (Host↔Client).
  Stream<Map<String, dynamic>> get onMessageReceived =>
      _messageController.stream;

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

    _setRole(BridgeRole.host);
    return HostSession(
      wifi: wifi,
      bleAdvertising: bleAdvertising,
      bleError: bleError,
    );
  }

  /// Stop Host mode and tear down all advertisements / servers.
  Future<void> stopHost() async {
    await _ble.stopHost();
    await _wifi.stopHost();
    if (_role == BridgeRole.host) {
      _setRole(BridgeRole.idle);
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

    void softError(String transport, Object error, StackTrace stackTrace) {
      // Keep the merged scan stream alive when one transport fails.
      // ignore: avoid_print
      print('nearby_dual_bridge $transport scan error: $error');
    }

    controller = StreamController<List<BridgeDevice>>(
      onListen: () async {
        // Tear down previous transport scans without closing this controller.
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
          _setRole(BridgeRole.client);
        }

        var started = 0;
        Object? lastStartError;

        if (wifi) {
          try {
            _wifiScanSub = _wifi.scanHosts(serviceUuid: serviceUuid).listen(
              ingest,
              onError: (Object e, StackTrace st) => softError('wifi', e, st),
            );
            started++;
          } catch (error) {
            lastStartError = error;
            softError('wifi', error, StackTrace.current);
          }
        }

        if (ble) {
          try {
            _bleScanSub = _ble.scanHosts(serviceUuid: serviceUuid).listen(
              ingest,
              onError: (Object e, StackTrace st) => softError('ble', e, st),
            );
            started++;
          } catch (error) {
            lastStartError = error;
            softError('ble', error, StackTrace.current);
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
    _setConnectionState(BridgeConnectionState.connecting);
    _setRole(BridgeRole.client);

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
          _setConnectionState(BridgeConnectionState.connected);
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
      _setConnectionState(BridgeConnectionState.disconnected);
      rethrow;
    }
  }

  /// Disconnect the active Client session.
  Future<void> disconnect() async {
    _setConnectionState(BridgeConnectionState.disconnecting);
    await _wifi.disconnect();
    await _ble.disconnect();
    _activeTransport = null;
    _setConnectionState(BridgeConnectionState.disconnected);
    if (_role == BridgeRole.client) {
      _setRole(BridgeRole.idle);
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
    await _wifi.dispose();
    await _ble.dispose();
    await _messageController.close();
    await _connectionStateController.close();
    await _roleController.close();
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

  void _setRole(BridgeRole role) {
    if (_role == role) return;
    _role = role;
    _roleController.add(role);
  }

  void _setConnectionState(BridgeConnectionState state) {
    if (_connectionState == state) return;
    _connectionState = state;
    _connectionStateController.add(state);
  }
}
