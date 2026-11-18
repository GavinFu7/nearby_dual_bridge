import 'dart:async';
import 'dart:collection';
import 'dart:convert';
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

  static const _bleStaleTimeout = Duration(seconds: 6);
  static const _bleStaleCheckInterval = Duration(seconds: 1);

  StreamController<List<BridgeDevice>>? _scanController;
  StreamSubscription? _discoveredSub;
  StreamSubscription? _writeSub;
  StreamSubscription? _notifyStateSub;
  StreamSubscription? _centralNotifiedSub;
  StreamSubscription? _centralConnectionSub;
  Timer? _scanStaleTimer;

  GATTCharacteristic? _hostCharacteristic;
  final _subscribedCentrals = <Central>{};
  Peripheral? _connectedPeripheral;
  GATTCharacteristic? _clientCharacteristic;
  String? _filterUuid;
  String? _hostDeviceName;
  bool _hosting = false;
  bool _scanning = false;
  bool _closingLink = false;
  bool _resolvingNames = false;
  bool _nameResolveRunning = false;

  final _lastPeripheralById = <String, Peripheral>{};
  final _lastAdvertisementAt = <String, DateTime>{};
  final _nameResolveQueue = Queue<String>();
  final _nameResolveQueuedOrDone = <String>{};
  final _resolvedNames = <String, String>{};

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

    _hostDeviceName = deviceName.trim().isEmpty ? 'NDB' : deviceName.trim();
    final serviceUuidObj = UUID.fromString(serviceUuid);
    final charUuid = UUID.fromString(BridgeConstants.messageCharacteristicUuid);
    final nameCharUuid =
        UUID.fromString(BridgeConstants.deviceNameCharacteristicUuid);

    final messageCharacteristic = GATTCharacteristic.mutable(
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
    _hostCharacteristic = messageCharacteristic;

    final nameCharacteristic = GATTCharacteristic.immutable(
      uuid: nameCharUuid,
      value: Uint8List.fromList(utf8.encode(_hostDeviceName!)),
      descriptors: const [],
    );

    final service = GATTService(
      uuid: serviceUuidObj,
      isPrimary: true,
      includedServices: const [],
      characteristics: [nameCharacteristic, messageCharacteristic],
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

    // Apple Local Name beside a 128-bit service UUID is ~8 bytes. Advertise only
    // the correlation code; full `code + displayName` is on the name characteristic.
    final advertiseName = _bleAdvertiseName(_hostDeviceName!);
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
    // Always attempt teardown even if `_hosting` drifted — scanners should stop
    // seeing this peripheral promptly after Stop Host.
    if (_peripheralManagerInstance != null) {
      try {
        await _peripheral.stopAdvertising();
      } catch (_) {}
      if (Platform.isAndroid) {
        try {
          final centrals = await _peripheral.retrieveConnectedCentrals();
          for (final central in centrals) {
            try {
              await _peripheral.disconnect(central);
            } catch (_) {}
          }
        } catch (_) {}
      }
      try {
        await _peripheral.removeAllServices();
      } catch (_) {}
    }
    _hosting = false;
    await _writeSub?.cancel();
    await _notifyStateSub?.cancel();
    _writeSub = null;
    _notifyStateSub = null;
    _hostCharacteristic = null;
    _hostDeviceName = null;
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
        _resetNameResolveState();
        _resolvingNames = true;
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
          _lastAdvertisementAt[peripheralKey] = DateTime.now();

          final advertisedName = advertisement.name?.trim();
          final previous = devices[peripheralKey];
          final fromAdvertise = advertisedName == null
              ? null
              : BridgeConstants.parseDeviceName(advertisedName);

          // Host restart changes the correlation code on the same peripheral.
          final cachedWire = _resolvedNames[peripheralKey];
          if (fromAdvertise != null && cachedWire != null) {
            final cached = BridgeConstants.parseDeviceName(cachedWire);
            if (cached != null && cached.code != fromAdvertise.code) {
              _resolvedNames.remove(peripheralKey);
              _nameResolveQueuedOrDone.remove(peripheralKey);
            }
          }

          final resolvedWire = _resolvedNames[peripheralKey];
          final fromResolved = resolvedWire == null
              ? null
              : BridgeConstants.parseDeviceName(resolvedWire);

          final correlationCode =
              fromAdvertise?.code ??
              fromResolved?.code ??
              previous?.correlationCode;
          final resolvedDisplay = fromResolved?.displayName.trim() ?? '';
          final nameResolved = resolvedDisplay.isNotEmpty;
          final displayName = nameResolved
              ? resolvedDisplay
              : (previous?.nameResolved == true ? previous!.name : '');

          final id = correlationCode != null
              ? BridgeConstants.deviceId(
                  serviceUuid: serviceUuid,
                  correlationCode: correlationCode,
                )
              : BridgeConstants.bleDeviceId(
                  serviceUuid: serviceUuid,
                  peripheralId: peripheralKey,
                );

          devices[peripheralKey] = BridgeDevice(
            id: id,
            name: displayName,
            serviceUuid: serviceUuid,
            correlationCode: correlationCode,
            nameResolved: nameResolved || (previous?.nameResolved ?? false),
            ble: BleEndpoint(
              peripheralId: peripheralKey,
              rssi: event.rssi,
              advertisedName: advertisedName ?? previous?.ble?.advertisedName,
            ),
            lastSeen: DateTime.now(),
          );
          _emitScanSnapshot(controller, devices);

          if (_resolvingNames &&
              _scanning &&
              !_nameResolveQueuedOrDone.contains(peripheralKey)) {
            _nameResolveQueuedOrDone.add(peripheralKey);
            _nameResolveQueue.add(peripheralKey);
            unawaited(
              _pumpNameResolveQueue(
                serviceUuid: serviceUuid,
                devices: devices,
                controller: controller,
              ),
            );
          }
        });
        await _central.startDiscovery(serviceUUIDs: [uuid]);
        _scanning = true;
        _scanStaleTimer?.cancel();
        _scanStaleTimer = Timer.periodic(_bleStaleCheckInterval, (_) {
          _pruneStaleScanDevices(devices, controller);
        });
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
    _resolvingNames = false;
    _nameResolveQueue.clear();
    _scanStaleTimer?.cancel();
    _scanStaleTimer = null;
    if (_scanning) {
      await _central.stopDiscovery();
      _scanning = false;
    }
    await _discoveredSub?.cancel();
    _discoveredSub = null;
    // Wait for in-flight name resolve to finish disconnecting.
    while (_nameResolveRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Drop BLE sightings that stopped advertising (e.g. after remote Stop Host).
  void _pruneStaleScanDevices(
    Map<String, BridgeDevice> devices,
    StreamController<List<BridgeDevice>> controller,
  ) {
    // Name resolve pauses discovery briefly; don't treat that gap as "gone".
    if (controller.isClosed ||
        devices.isEmpty ||
        !_scanning ||
        _nameResolveRunning) {
      return;
    }
    final now = DateTime.now();
    final staleKeys = <String>[];
    for (final key in devices.keys) {
      final last = _lastAdvertisementAt[key];
      if (last == null || now.difference(last) > _bleStaleTimeout) {
        staleKeys.add(key);
      }
    }
    if (staleKeys.isEmpty) return;
    for (final key in staleKeys) {
      devices.remove(key);
      _lastAdvertisementAt.remove(key);
      // Allow a later reappearance (new Host session) to resolve again.
      _nameResolveQueuedOrDone.remove(key);
    }
    _emitScanSnapshot(controller, devices);
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

  void _resetNameResolveState() {
    _nameResolveQueue.clear();
    _nameResolveQueuedOrDone.clear();
    // Keep _resolvedNames across stop/start within process so rediscovery is faster.
  }

  void _emitScanSnapshot(
    StreamController<List<BridgeDevice>> controller,
    Map<String, BridgeDevice> devices,
  ) {
    if (controller.isClosed) return;
    controller.add(devices.values.toList(growable: false));
  }

  Future<void> _pumpNameResolveQueue({
    required String serviceUuid,
    required Map<String, BridgeDevice> devices,
    required StreamController<List<BridgeDevice>> controller,
  }) async {
    if (_nameResolveRunning) return;
    _nameResolveRunning = true;
    try {
      while (_resolvingNames && _nameResolveQueue.isNotEmpty) {
        final peripheralKey = _nameResolveQueue.removeFirst();
        try {
          final fullName = await _resolvePeripheralName(peripheralKey);
          if (!_resolvingNames) break;
          if (fullName == null || fullName.isEmpty) continue;

          _resolvedNames[peripheralKey] = fullName;
          final existing = devices[peripheralKey];
          if (existing == null) continue;

          final parsed = BridgeConstants.parseDeviceName(fullName);
          final correlationCode = parsed?.code ?? existing.correlationCode;
          final displayName = parsed == null
              ? fullName.trim()
              : parsed.displayName.trim();
          if (displayName.isEmpty) continue;

          final id = correlationCode != null
              ? BridgeConstants.deviceId(
                  serviceUuid: serviceUuid,
                  correlationCode: correlationCode,
                )
              : existing.id;

          devices[peripheralKey] = existing.copyWith(
            id: id,
            name: displayName,
            correlationCode: correlationCode,
            nameResolved: true,
            lastSeen: DateTime.now(),
          );
          _emitScanSnapshot(controller, devices);
        } catch (_) {
          // Keep scanning; name resolve is best-effort.
        }
      }
    } finally {
      _nameResolveRunning = false;
      if (_resolvingNames && _scanning == false) {
        // Resolver paused discovery to connect; resume if still resolving.
      }
    }
  }

  /// Connect briefly, read full device name, disconnect. Does not emit peer events.
  Future<String?> _resolvePeripheralName(String peripheralKey) async {
    final peripheral = _lastPeripheralById[peripheralKey];
    if (peripheral == null) return null;

    // iOS/macOS generally require stopping scan before connecting.
    final wasScanning = _scanning;
    if (wasScanning) {
      await _central.stopDiscovery();
      _scanning = false;
    }

    try {
      await _central.connect(peripheral);
      try {
        final services = await _central.discoverGATT(peripheral);
        final nameCharUuid =
            UUID.fromString(BridgeConstants.deviceNameCharacteristicUuid);
        final gapNameUuid = UUID.short(0x2A00);

        for (final service in services) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid != nameCharUuid &&
                characteristic.uuid != gapNameUuid) {
              continue;
            }
            if (!characteristic.properties
                .contains(GATTCharacteristicProperty.read)) {
              continue;
            }
            final bytes = await _central.readCharacteristic(
              peripheral,
              characteristic,
            );
            final name = utf8.decode(bytes).trim();
            if (name.isNotEmpty) {
              return name;
            }
          }
        }
      } finally {
        try {
          await _central.disconnect(peripheral);
        } catch (_) {}
      }
    } finally {
      if (_resolvingNames &&
          wasScanning &&
          _scanController != null &&
          !_scanController!.isClosed) {
        final uuid = UUID.fromString(
          _filterUuid ?? BridgeConstants.defaultServiceUuid,
        );
        await _central.startDiscovery(serviceUUIDs: [uuid]);
        _scanning = true;
      }
    }
    return null;
  }

  @override
  Future<void> connect(
    BleEndpoint endpoint, {
    String? serviceUuid,
  }) async {
    // Formal session connect must not race with name resolve.
    _resolvingNames = false;
    _nameResolveQueue.clear();
    while (_nameResolveRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

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

    if (_scanning) {
      await _central.stopDiscovery();
      _scanning = false;
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
    _centralNotifiedSub = _central.characteristicNotified.listen((event) {
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

  /// Advertise Local Name = correlation code only (Apple ~8-byte limit).
  String _bleAdvertiseName(String wireDeviceName) {
    final parsed = BridgeConstants.parseDeviceName(wireDeviceName);
    if (parsed != null) return parsed.code;
    final trimmed = wireDeviceName.trim();
    if (trimmed.isEmpty) return 'NDB';
    if (trimmed.length <= BridgeConstants.correlationCodeLength) {
      return trimmed;
    }
    return trimmed.substring(0, BridgeConstants.correlationCodeLength);
  }
}
