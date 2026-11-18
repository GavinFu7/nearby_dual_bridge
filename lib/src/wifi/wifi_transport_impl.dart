import 'dart:async';
import 'dart:io';

import 'package:nsd/nsd.dart';

import '../bridge_constants.dart';
import '../interfaces/wifi_transport.dart';
import '../models/bridge_device.dart';
import '../models/bridge_peer_event.dart';
import '../models/transport_type.dart';
import '../models/wifi_endpoint.dart';
import '../protocol/message_codec.dart';

/// Wi-Fi transport: mDNS (`nsd`) + WebSocket (`dart:io`).
class WifiTransportImpl implements WifiTransport {
  WifiTransportImpl({this.codec = const MessageCodec()});

  final MessageCodec codec;

  HttpServer? _server;
  Registration? _registration;
  Discovery? _discovery;
  StreamController<List<BridgeDevice>>? _scanController;
  StreamSubscription? _discoveryListener;
  final _sockets = <WebSocket>{};
  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _peerController = StreamController<BridgePeerEvent>.broadcast();
  WebSocket? _clientSocket;
  String? _filterUuid;
  bool _closingSocket = false;

  @override
  Stream<Map<String, dynamic>> get onMessageReceived =>
      _messageController.stream;

  @override
  Stream<BridgePeerEvent> get onPeerConnectionChanged =>
      _peerController.stream;

  @override
  Future<WifiEndpoint> startHost({
    required String deviceName,
    required String serviceUuid,
    int? port,
  }) async {
    await stopHost();

    final server = await HttpServer.bind(InternetAddress.anyIPv4, port ?? 0);
    _server = server;
    server.listen(_handleHttpRequest);

    final endpoint = WifiEndpoint(
      host: await _localHostName(),
      port: server.port,
      serviceName: deviceName,
    );

    _registration = await register(
      Service(
        name: deviceName,
        type: BridgeConstants.mdnsServiceType,
        port: server.port,
        txt: BridgeConstants.mdnsTxt(
          serviceUuid: serviceUuid,
          deviceName: deviceName,
        ),
      ),
    );

    return endpoint;
  }

  @override
  Future<void> stopHost() async {
    final registration = _registration;
    _registration = null;
    if (registration != null) {
      await unregister(registration);
    }

    for (final socket in List<WebSocket>.from(_sockets)) {
      await socket.close();
    }
    _sockets.clear();

    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  @override
  Stream<List<BridgeDevice>> scanHosts({required String serviceUuid}) {
    _filterUuid = serviceUuid.trim().toLowerCase();
    final devices = <String, BridgeDevice>{};
    late final StreamController<List<BridgeDevice>> controller;
    controller = StreamController<List<BridgeDevice>>(
      onListen: () async {
        // Stop previous discovery engine only — never close *this* controller.
        await _stopDiscoveryEngine();
        try {
          // Prefer IPv4 lookup: Host binds IPv4, and link-local IPv6 often
          // yields "Connection refused" from iPhone → Mac.
          final discovery = await startDiscovery(
            BridgeConstants.mdnsServiceType,
            autoResolve: true,
            ipLookupType: IpLookupType.v4,
          );
          _discovery = discovery;
          discovery.addServiceListener((service, status) {
            final device = _deviceFromService(service);
            if (device == null) return;
            if (status == ServiceStatus.found) {
              devices[device.id] = device;
            } else {
              devices.remove(device.id);
            }
            if (!controller.isClosed) {
              controller.add(devices.values.toList(growable: false));
            }
          });
        } catch (error, stackTrace) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
        }
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
    await _discoveryListener?.cancel();
    _discoveryListener = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      await stopDiscovery(discovery);
    }
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
  Future<void> connect(WifiEndpoint endpoint) async {
    await disconnect();

    Object? lastError;
    for (final uri in endpoint.connectionCandidates) {
      try {
        final socket = await WebSocket.connect(uri.toString());
        _clientSocket = socket;
        _sockets.add(socket);
        _attachSocket(socket, emitConnected: true);
        return;
      } catch (error) {
        lastError = error;
      }
    }

    throw StateError(
      'Unable to connect to ${endpoint.serviceName ?? endpoint.host}: $lastError',
    );
  }

  @override
  Future<void> disconnect() async {
    final socket = _clientSocket;
    _clientSocket = null;
    if (socket != null) {
      _closingSocket = true;
      _sockets.remove(socket);
      try {
        await socket.close();
      } finally {
        _closingSocket = false;
      }
      _emitPeer(BridgePeerEventType.disconnected);
    }
  }

  @override
  Future<void> sendMessage(Map<String, dynamic> data) async {
    final raw = codec.encode(data);
    final targets = <WebSocket>[
      ?_clientSocket,
      ..._sockets.where((s) => s != _clientSocket),
    ];
    if (targets.isEmpty) {
      throw StateError('No Wi-Fi peer connected');
    }
    for (final socket in targets) {
      socket.add(raw);
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

  Future<void> _handleHttpRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    _attachSocket(socket, emitConnected: true);
  }

  void _attachSocket(WebSocket socket, {bool emitConnected = false}) {
    if (emitConnected || identical(socket, _clientSocket)) {
      _emitPeer(BridgePeerEventType.connected);
    }
    socket.listen(
      (event) {
        try {
          if (event is String) {
            _messageController.add(codec.decode(event));
          } else if (event is List<int>) {
            _messageController.add(codec.decodeBytes(event));
          }
        } catch (_) {
          // Ignore malformed frames.
        }
      },
      onDone: () => _handleSocketClosed(socket),
      onError: (_) => _handleSocketClosed(socket),
      cancelOnError: true,
    );
  }

  void _handleSocketClosed(WebSocket socket) {
    final removed = _sockets.remove(socket);
    if (identical(_clientSocket, socket)) {
      _clientSocket = null;
    }
    if (removed && !_closingSocket) {
      _emitPeer(BridgePeerEventType.disconnected);
    }
  }

  int get _peerCount => _sockets.length;

  void _emitPeer(BridgePeerEventType type) {
    if (_peerController.isClosed) return;
    _peerController.add(
      BridgePeerEvent(
        transport: TransportType.wifi,
        type: type,
        peerCount: _peerCount,
      ),
    );
  }

  BridgeDevice? _deviceFromService(Service service) {
    final wireName = service.name;
    if (wireName == null || wireName.isEmpty) return null;

    final txtUuid = BridgeConstants.txtString(
      service.txt,
      BridgeConstants.txtUuidKey,
    )?.toLowerCase();
    if (_filterUuid != null &&
        txtUuid != null &&
        txtUuid != _filterUuid) {
      return null;
    }
    // If TXT missing, still accept when discovery is scoped by app usage;
    // require TXT match when present filter is set and txt exists.
    if (_filterUuid != null && txtUuid == null) {
      // Keep devices without TXT only if name is present — filter loosely.
    }

    final host = service.host;
    final port = service.port;
    if (host == null || port == null) return null;

    final serviceUuid = txtUuid ?? _filterUuid ?? BridgeConstants.defaultServiceUuid;
    final addresses =
        service.addresses?.map((a) => a.address).toList(growable: false) ??
            const <String>[];

    final parsed = BridgeConstants.parseDeviceName(wireName);
    final correlationCode = parsed?.code;
    final displayName = parsed == null
        ? wireName
        : (parsed.displayName.trim().isEmpty
            ? wireName
            : parsed.displayName.trim());

    return BridgeDevice(
      id: BridgeConstants.deviceId(
        serviceUuid: serviceUuid,
        correlationCode: correlationCode ?? wireName,
      ),
      name: displayName,
      serviceUuid: serviceUuid,
      correlationCode: correlationCode,
      nameResolved: true,
      wifi: WifiEndpoint(
        host: host,
        port: port,
        addresses: addresses,
        serviceName: wireName,
      ),
      lastSeen: DateTime.now(),
    );
  }

  Future<String> _localHostName() async {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'localhost';
    }
  }
}
