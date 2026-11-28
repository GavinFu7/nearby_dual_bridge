import 'dart:async';
import 'dart:io';

import 'package:nsd/nsd.dart';

import '../bridge_constants.dart';
import '../interfaces/wifi_transport.dart';
import '../models/bridge_device.dart';
import '../models/bridge_peer.dart';
import '../models/bridge_peer_event.dart';
import '../models/transport_type.dart';
import '../models/wifi_endpoint.dart';
import '../models/wifi_host_result.dart';
import '../protocol/message_codec.dart';

class _WifiHostPeer {
  _WifiHostPeer({
    required this.id,
    required this.socket,
    required this.peer,
  });

  final String id;
  final WebSocket socket;
  BridgePeer peer;
}

/// Wi-Fi transport: mDNS (`nsd`) + WebSocket (`dart:io`).
class WifiTransportImpl implements WifiTransport {
  WifiTransportImpl({this.codec = const MessageCodec()});

  final MessageCodec codec;

  HttpServer? _server;
  Registration? _registration;
  Discovery? _discovery;
  StreamController<List<BridgeDevice>>? _scanController;
  ServiceListener? _serviceListener;
  final _hostPeers = <String, _WifiHostPeer>{};
  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _peerController = StreamController<BridgePeerEvent>.broadcast();
  WebSocket? _clientSocket;
  String? _filterUuid;
  bool _closingSocket = false;
  bool _requireConnectionApproval = true;
  int _peerSeq = 0;

  @override
  Stream<Map<String, dynamic>> get onMessageReceived =>
      _messageController.stream;

  @override
  Stream<BridgePeerEvent> get onPeerConnectionChanged =>
      _peerController.stream;

  @override
  List<BridgePeer> get hostPeers =>
      _hostPeers.values.map((e) => e.peer).toList(growable: false);

  @override
  Future<WifiHostResult> startHost({
    required String deviceName,
    required String serviceUuid,
    int? port,
    bool requireConnectionApproval = true,
  }) async {
    await stopHost();
    _requireConnectionApproval = requireConnectionApproval;

    final server = await HttpServer.bind(InternetAddress.anyIPv4, port ?? 0);
    _server = server;
    server.listen(_handleHttpRequest);

    final endpoint = WifiEndpoint(
      host: await _localHostName(),
      port: server.port,
      serviceName: deviceName,
    );

    final registerFuture = register(
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
    try {
      _registration = await registerFuture.timeout(_mdnsRegisterTimeout);
      return WifiHostResult(
        endpoint: endpoint,
        mdnsRegistered: true,
      );
    } on TimeoutException catch (error) {
      // Don't block Host start: WebSocket is already up. If Bonjour finishes
      // later while this server is still running, keep the registration;
      // otherwise unregister so we don't leak a stale advertisement.
      unawaited(() async {
        try {
          final reg = await registerFuture;
          if (!identical(_server, server)) {
            await unregister(reg);
            return;
          }
          _registration = reg;
        } catch (_) {}
      }());
      return WifiHostResult(
        endpoint: endpoint,
        mdnsRegistered: false,
        mdnsError: error,
      );
    } catch (error) {
      return WifiHostResult(
        endpoint: endpoint,
        mdnsRegistered: false,
        mdnsError: error,
      );
    }
  }

  @override
  Future<void> stopHost() async {
    final registration = _registration;
    _registration = null;
    if (registration != null) {
      await unregister(registration);
    }

    for (final session in List<_WifiHostPeer>.from(_hostPeers.values)) {
      await _closeHostPeer(session, emit: false);
    }
    _hostPeers.clear();

    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  @override
  Future<void> approvePeer(String peerId) async {
    final session = _hostPeers[peerId];
    if (session == null) {
      throw StateError('Unknown Wi-Fi peer: $peerId');
    }
    if (session.peer.state == BridgePeerState.connected) return;
    session.peer = session.peer.copyWith(state: BridgePeerState.connected);
    _emitPeer(BridgePeerEventType.connected, peer: session.peer);
  }

  @override
  Future<void> rejectPeer(String peerId) async {
    final session = _hostPeers[peerId];
    if (session == null) {
      throw StateError('Unknown Wi-Fi peer: $peerId');
    }
    if (session.peer.state != BridgePeerState.pending) {
      throw StateError('Wi-Fi peer $peerId is not pending');
    }
    final peer = session.peer;
    await _closeHostPeer(session, emit: false);
    _emitPeer(BridgePeerEventType.rejected, peer: peer);
  }

  @override
  Future<void> disconnectPeer(String peerId) async {
    final session = _hostPeers[peerId];
    if (session == null) {
      throw StateError('Unknown Wi-Fi peer: $peerId');
    }
    final peer = session.peer;
    await _closeHostPeer(session, emit: false);
    _emitPeer(BridgePeerEventType.disconnected, peer: peer);
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
          void listener(Service service, ServiceStatus status) {
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
          }

          _serviceListener = listener;
          discovery.addServiceListener(listener);
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
    final listener = _serviceListener;
    _serviceListener = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null && listener != null) {
      discovery.removeServiceListener(listener);
    }
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

  static const _mdnsRegisterTimeout = Duration(seconds: 3);
  static const _wifiConnectTimeout = Duration(seconds: 8);

  @override
  Future<void> connect(WifiEndpoint endpoint) async {
    await disconnect();

    Object? lastError;
    for (final uri in endpoint.connectionCandidates) {
      final connectFuture = WebSocket.connect(uri.toString());
      try {
        final socket = await connectFuture.timeout(_wifiConnectTimeout);
        _clientSocket = socket;
        _attachClientSocket(socket);
        return;
      } on TimeoutException catch (error) {
        lastError = error;
        // Timed-out connect may still complete later; close orphan sockets.
        unawaited(
          connectFuture.then((ws) => ws.close()).catchError((_) {}),
        );
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
    final client = _clientSocket;
    if (client != null) {
      client.add(raw);
      return;
    }

    final targets = _hostPeers.values
        .where((s) => s.peer.state == BridgePeerState.connected)
        .map((s) => s.socket)
        .toList(growable: false);
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
    final remote = request.connectionInfo?.remoteAddress.address;
    final remotePort = request.connectionInfo?.remotePort;
    final id = 'wifi:${remote ?? 'unknown'}:${remotePort ?? ++_peerSeq}';
    final label = remote == null
        ? id
        : (remotePort == null ? remote : '$remote:$remotePort');
    final peer = BridgePeer(
      id: id,
      transport: TransportType.wifi,
      state: _requireConnectionApproval
          ? BridgePeerState.pending
          : BridgePeerState.connected,
      label: label,
      remoteAddress: remote,
      connectedAt: DateTime.now(),
    );
    final session = _WifiHostPeer(id: id, socket: socket, peer: peer);
    _hostPeers[id] = session;
    _attachHostSocket(session);

    if (_requireConnectionApproval) {
      _emitPeer(BridgePeerEventType.connectionRequest, peer: peer);
    } else {
      _emitPeer(BridgePeerEventType.connected, peer: peer);
    }
  }

  void _attachHostSocket(_WifiHostPeer session) {
    session.socket.listen(
      (event) {
        if (session.peer.state != BridgePeerState.connected) {
          return;
        }
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
      onDone: () => _handleHostSocketClosed(session),
      onError: (_) => _handleHostSocketClosed(session),
      cancelOnError: true,
    );
  }

  void _attachClientSocket(WebSocket socket) {
    _emitPeer(BridgePeerEventType.connected);
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
      onDone: () => _handleClientSocketClosed(socket),
      onError: (_) => _handleClientSocketClosed(socket),
      cancelOnError: true,
    );
  }

  void _handleHostSocketClosed(_WifiHostPeer session) {
    final removed = _hostPeers.remove(session.id);
    if (removed == null || _closingSocket) return;
    _emitPeer(BridgePeerEventType.disconnected, peer: session.peer);
  }

  void _handleClientSocketClosed(WebSocket socket) {
    if (!identical(_clientSocket, socket)) return;
    _clientSocket = null;
    if (!_closingSocket) {
      _emitPeer(BridgePeerEventType.disconnected);
    }
  }

  Future<void> _closeHostPeer(_WifiHostPeer session, {required bool emit}) async {
    _closingSocket = true;
    _hostPeers.remove(session.id);
    try {
      await session.socket.close();
    } catch (_) {
    } finally {
      _closingSocket = false;
    }
    if (emit) {
      _emitPeer(BridgePeerEventType.disconnected, peer: session.peer);
    }
  }

  int get _approvedPeerCount => _hostPeers.values
      .where((s) => s.peer.state == BridgePeerState.connected)
      .length;

  void _emitPeer(BridgePeerEventType type, {BridgePeer? peer}) {
    if (_peerController.isClosed) return;
    _peerController.add(
      BridgePeerEvent(
        transport: TransportType.wifi,
        type: type,
        peerCount: _clientSocket != null ? 1 : _approvedPeerCount,
        peer: peer,
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
