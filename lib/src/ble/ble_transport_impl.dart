import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../bridge_constants.dart';
import '../interfaces/ble_transport.dart';
import '../models/ble_endpoint.dart';
import '../models/bridge_device.dart';
import '../models/bridge_peer_event.dart';
import '../models/transport_type.dart';
import '../protocol/ble_chunk_protocol.dart';

/// BLE dual-role transport via `bluetooth_low_energy`.
class BleTransportImpl implements BleTransport {
  BleTransportImpl({BleChunkProtocol? protocol})
      : _protocol = protocol ?? BleChunkProtocol();

  final BleChunkProtocol _protocol;
  PeripheralManager? _peripheralManagerInstance;
  CentralManager? _centralManagerInstance;

  PeripheralManager get _peripheral =>
      _peripheralManagerInstance ??= PeripheralManager();
  CentralManager get _central =>
      _centralManagerInstance ??= CentralManager();

  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _peerController = StreamController<BridgePeerEvent>.broadcast();
  final _hostReassembler = BleChunkReassembler();
  final _clientReassembler = BleChunkReassembler();

  StreamController<List<BridgeDevice>>? _scanController;
  StreamSubscription? _discoveredSub;
  StreamSubscription? _writeSub;
  StreamSubscription? _notifyStateSub;
  StreamSubscription? _centralNotifiedSub;
  StreamSubscription? _centralConnectionSub;

  GATTCharacteristic? _hostCharacteristic;
  final _subscribedCentrals = <Central>{};
  Peripheral? _connectedPeripheral;
  GATTCharacteristic? _clientCharacteristic;
  String? _filterUuid;
  bool _hosting = false;
  bool _scanning = false;
  bool _closingLink = false;

  @override
  Stream<Map<String, dynamic>> get onMessageReceived =>
      _messageController.stream;

  @override
  Stream<BridgePeerEvent> get onPeerConnectionChanged =>
      _peerController.stream;

  @override
  Future<void> startHost({
    required String deviceName,
    required String serviceUuid,
  }) async {
    await stopHost();
    await _ensureReady(_peripheral);

    final serviceUuidObj = UUID.fromString(serviceUuid);
    final charUuid = UUID.fromString(BridgeConstants.messageCharacteristicUuid);

    final characteristic = GATTCharacteristic.mutable(
      uuid: charUuid,
      properties: const [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
        GATTCharacteristicProperty.notify,
      ],
      permissions: const [
        GATTCharacteristicPermission.read,
        GATTCharacteristicPermission.write,
      ],
      descriptors: const [],
    );
    _hostCharacteristic = characteristic;

    final service = GATTService(
      uuid: serviceUuidObj,
      isPrimary: true,
      includedServices: const [],
      characteristics: [characteristic],
    );

    await _peripheral.removeAllServices();
    await _peripheral.addService(service);

    _writeSub = _peripheral.characteristicWriteRequested.listen(
      (event) async {
        if (event.characteristic.uuid != charUuid) return;
        try {
          final message = _hostReassembler.add(
            Uint8List.fromList(event.request.value),
          );
          await _peripheral.respondWriteRequest(event.request);
          if (message != null) {
            _messageController.add(message);
          }
        } catch (_) {
          await _peripheral.respondWriteRequestWithError(
            event.request,
            error: GATTError.invalidAttributeValueLength,
          );
        }
      },
    );

    _notifyStateSub =
        _peripheral.characteristicNotifyStateChanged.listen((event) {
      if (event.characteristic.uuid != charUuid) return;
      if (event.state) {
        final added = _subscribedCentrals.add(event.central);
        if (added) {
          _emitPeer(BridgePeerEventType.connected);
        }
      } else {
        final removed = _subscribedCentrals.remove(event.central);
        if (removed) {
          _emitPeer(BridgePeerEventType.disconnected);
        }
      }
    });

    // Apple drops Local Name when it doesn't fit beside a 128-bit service UUID
    // (often ~8 bytes on modern macOS). Keep a short advertise name.
    final advertiseName = _bleAdvertiseName(deviceName);
    await _peripheral.startAdvertising(
      Advertisement(
        name: Platform.isWindows ? null : advertiseName,
        serviceUUIDs: [serviceUuidObj],
      ),
    );
    _hosting = true;
  }

  @override
  Future<void> stopHost() async {
    if (_hosting) {
      await _peripheral.stopAdvertising();
      await _peripheral.removeAllServices();
      _hosting = false;
    }
    await _writeSub?.cancel();
    await _notifyStateSub?.cancel();
    _writeSub = null;
    _notifyStateSub = null;
    _hostCharacteristic = null;
    _subscribedCentrals.clear();
    _hostReassembler.reset();
  }

  @override
  Stream<List<BridgeDevice>> scanHosts({required String serviceUuid}) {
    _filterUuid = serviceUuid.trim().toLowerCase();
    final devices = <String, BridgeDevice>{};
    late final StreamController<List<BridgeDevice>> controller;
    controller = StreamController<List<BridgeDevice>>(
      onListen: () async {
        await _stopDiscoveryEngine();
        try {
          await _ensureReady(_central);
        } catch (error, stackTrace) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
          return;
        }
        final uuid = UUID.fromString(serviceUuid);
        _discoveredSub = _central.discovered.listen((event) {
          final advertisement = event.advertisement;
          final peripheralKey =
              event.peripheral.uuid.toString().toLowerCase();
          _lastPeripheralById[peripheralKey] = event.peripheral;

          // iOS/macOS often omit Local Name when advertising a 128-bit UUID.
          // Still surface the peripheral so discovery is not silently dropped.
          final advertisedName = advertisement.name?.trim();
          final name = (advertisedName != null && advertisedName.isNotEmpty)
              ? advertisedName
              : 'BLE-${peripheralKey.replaceAll('-', '').substring(0, 6)}';

          final id = BridgeConstants.deviceId(
            serviceUuid: serviceUuid,
            name: name,
          );
          devices[id] = BridgeDevice(
            id: id,
            name: name,
            serviceUuid: serviceUuid,
            ble: BleEndpoint(
              peripheralId: peripheralKey,
              rssi: event.rssi,
              advertisedName: advertisedName,
            ),
            lastSeen: DateTime.now(),
          );
          if (!controller.isClosed) {
            controller.add(devices.values.toList(growable: false));
          }
        });
        await _central.startDiscovery(serviceUUIDs: [uuid]);
        _scanning = true;
      },
      onCancel: _stopDiscoveryEngine,
    );

    final previous = _scanController;
    _scanController = controller;
    if (previous != null && !previous.isClosed) {
      unawaited(previous.close());
    }
    return controller.stream;
  }

  Future<void> _stopDiscoveryEngine() async {
    if (_scanning) {
      await _central.stopDiscovery();
      _scanning = false;
    }
    await _discoveredSub?.cancel();
    _discoveredSub = null;
  }

  @override
  Future<void> stopScan() async {
    await _stopDiscoveryEngine();
    final controller = _scanController;
    _scanController = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  @override
  Future<void> connect(
    BleEndpoint endpoint, {
    String? serviceUuid,
  }) async {
    await disconnect();
    await _ensureReady(_central);

    if (serviceUuid != null) {
      _filterUuid = serviceUuid.trim().toLowerCase();
    }

    final resolved = _lastPeripheralById[_normalizeUuid(endpoint.peripheralId)];
    if (resolved == null) {
      throw StateError(
        'BLE peripheral ${endpoint.peripheralId} is not in the discovery cache. '
        'Scan again before connecting.',
      );
    }

    await _centralConnectionSub?.cancel();
    _centralConnectionSub = _central.connectionStateChanged.listen((event) {
      if (event.peripheral != resolved) return;
      if (event.state == ConnectionState.disconnected) {
        _connectedPeripheral = null;
        _clientCharacteristic = null;
        if (!_closingLink) {
          _emitPeer(BridgePeerEventType.disconnected);
        }
      }
    });

    await _central.connect(resolved);
    _connectedPeripheral = resolved;
    _emitPeer(BridgePeerEventType.connected);

    final services = await _central.discoverGATT(resolved);
    final resolvedServiceUuid =
        _filterUuid ?? BridgeConstants.defaultServiceUuid;
    final service = services.firstWhere(
      (s) =>
          s.uuid.toString().toLowerCase() ==
          resolvedServiceUuid.toLowerCase(),
      orElse: () => throw StateError('Bridge GATT service not found'),
    );
    final charUuid =
        UUID.fromString(BridgeConstants.messageCharacteristicUuid);
    final characteristic = service.characteristics.firstWhere(
      (c) => c.uuid == charUuid,
      orElse: () => throw StateError('Bridge message characteristic not found'),
    );
    _clientCharacteristic = characteristic;

    await _central.setCharacteristicNotifyState(
      resolved,
      characteristic,
      state: true,
    );

    await _centralNotifiedSub?.cancel();
    _centralNotifiedSub = _central.characteristicNotified.listen((
      event,
    ) {
      if (event.peripheral != resolved) return;
      if (event.characteristic.uuid != charUuid) return;
      try {
        final message = _clientReassembler.add(
          Uint8List.fromList(event.value),
        );
        if (message != null) {
          _messageController.add(message);
        }
      } catch (_) {
        _clientReassembler.reset();
      }
    });
  }

  final _lastPeripheralById = <String, Peripheral>{};

  @override
  Future<void> disconnect() async {
    await _centralNotifiedSub?.cancel();
    _centralNotifiedSub = null;
    final peripheral = _connectedPeripheral;
    _connectedPeripheral = null;
    _clientCharacteristic = null;
    _clientReassembler.reset();
    if (peripheral != null) {
      _closingLink = true;
      try {
        await _central.disconnect(peripheral);
      } finally {
        _closingLink = false;
      }
      _emitPeer(BridgePeerEventType.disconnected);
    }
    await _centralConnectionSub?.cancel();
    _centralConnectionSub = null;
  }

  @override
  Future<void> sendMessage(Map<String, dynamic> data) async {
    final frames = _protocol.encode(data);

    // Host path: notify subscribed centrals.
    final hostChar = _hostCharacteristic;
    if (_hosting && hostChar != null && _subscribedCentrals.isNotEmpty) {
      for (final central in List<Central>.from(_subscribedCentrals)) {
        for (final frame in frames) {
          final maxLen =
              await _peripheral.getMaximumNotifyLength(central);
          if (frame.length > maxLen) {
            // Re-chunk with tighter payload if MTU is smaller than assumed.
            final tight = BleChunkProtocol(maxPayloadPerChunk: maxLen - 5)
                .encode(data);
            for (final part in tight) {
              await _peripheral.notifyCharacteristic(
                central,
                hostChar,
                value: part,
              );
            }
            break;
          }
          await _peripheral.notifyCharacteristic(
            central,
            hostChar,
            value: frame,
          );
        }
      }
      return;
    }

    // Client path: write to peripheral characteristic.
    final peripheral = _connectedPeripheral;
    final characteristic = _clientCharacteristic;
    if (peripheral == null || characteristic == null) {
      throw StateError('No BLE peer connected');
    }

    final writeType = characteristic.properties.contains(
          GATTCharacteristicProperty.writeWithoutResponse,
        )
        ? GATTCharacteristicWriteType.withoutResponse
        : GATTCharacteristicWriteType.withResponse;

    for (final frame in frames) {
      final maxLen = await _central.getMaximumWriteLength(
        peripheral,
        type: writeType,
      );
      if (frame.length <= maxLen) {
        await _central.writeCharacteristic(
          peripheral,
          characteristic,
          value: frame,
          type: writeType,
        );
      } else {
        final tight =
            BleChunkProtocol(maxPayloadPerChunk: maxLen - 5).encode(data);
        for (final part in tight) {
          await _central.writeCharacteristic(
            peripheral,
            characteristic,
            value: part,
            type: writeType,
          );
        }
        break;
      }
    }
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    await stopHost();
    await disconnect();
    await _messageController.close();
    await _peerController.close();
  }

  int get _peerCount {
    if (_connectedPeripheral != null) return 1;
    return _subscribedCentrals.length;
  }

  void _emitPeer(BridgePeerEventType type) {
    if (_peerController.isClosed) return;
    _peerController.add(
      BridgePeerEvent(
        transport: TransportType.ble,
        type: type,
        peerCount: _peerCount,
      ),
    );
  }

  Future<void> _ensureReady(BluetoothLowEnergyManager manager) async {
    Future<void> authorizeIfNeeded() async {
      if (Platform.isAndroid &&
          manager.state == BluetoothLowEnergyState.unauthorized) {
        await manager.authorize();
      }
    }

    await authorizeIfNeeded();
    if (manager.state == BluetoothLowEnergyState.poweredOn) {
      return;
    }

    final completer = Completer<void>();
    late final StreamSubscription sub;
    sub = manager.stateChanged.listen((event) async {
      if (event.state == BluetoothLowEnergyState.unauthorized &&
          Platform.isAndroid) {
        await manager.authorize();
      }
      if (event.state == BluetoothLowEnergyState.poweredOn &&
          !completer.isCompleted) {
        completer.complete();
      }
      if ((event.state == BluetoothLowEnergyState.poweredOff ||
              event.state == BluetoothLowEnergyState.unsupported) &&
          !completer.isCompleted) {
        completer.completeError(
          StateError('Bluetooth unavailable: ${event.state}'),
        );
      }
    });
    try {
      await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      await sub.cancel();
    }
  }

  String _normalizeUuid(String value) => value.trim().toLowerCase();

  /// Shorten names for Apple BLE advertise payload limits.
  String _bleAdvertiseName(String deviceName) {
    final trimmed = deviceName.trim();
    if (trimmed.isEmpty) return 'NDB';
    if (trimmed.length <= 8) return trimmed;
    return trimmed.substring(0, 8);
  }
}
