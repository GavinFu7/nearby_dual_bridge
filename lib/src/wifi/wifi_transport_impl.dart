import 'dart:async';
import 'dart:io';

import 'package:nsd/nsd.dart';

import '../bridge_constants.dart';
import '../interfaces/wifi_transport.dart';
import '../models/bridge_device.dart';
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
  WebSocket? _clientSocket;
  String? _filterUuid;

  @override
  Stream<Map<String, dynamic>> get onMessageReceived =>
      _messageController.stream;

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
            // ignore: avoid_print
            print(
              '[NDB][wifi] $status name=${service.name} host=${service.host} '
              'port=${service.port} txt=${service.txt?.keys}',
            );
            final device = _deviceFromService(service);
            if (device == null) {
              // ignore: avoid_print
              print(
                '[NDB][wifi] skipped unresolved/filtered service '
                'name=${service.name} host=${service.host} port=${service.port}',
              );
              return;
            }
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
        // ignore: avoid_print
        print('[NDB][wifi] connecting $uri');
        final socket = await WebSocket.connect(uri.toString());
        _clientSocket = socket;
        _attachSocket(socket);
        return;
      } catch (error) {
        lastError = error;
        // ignore: avoid_print
        print('[NDB][wifi] connect failed $uri → $error');
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
      _sockets.remove(socket);
      await socket.close();
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
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    _attachSocket(socket);
  }

  void _attachSocket(WebSocket socket) {
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
      onDone: () => _sockets.remove(socket),
      onError: (_) => _sockets.remove(socket),
      cancelOnError: true,
    );
  }

  BridgeDevice? _deviceFromService(Service service) {
    final name = service.name;
    if (name == null || name.isEmpty) return null;

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

    return BridgeDevice(
      id: BridgeConstants.deviceId(serviceUuid: serviceUuid, name: name),
      name: name,
      serviceUuid: serviceUuid,
      wifi: WifiEndpoint(
        host: host,
        port: port,
        addresses: addresses,
        serviceName: name,
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
