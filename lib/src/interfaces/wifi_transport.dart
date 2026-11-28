import '../models/bridge_device.dart';
import '../models/bridge_peer.dart';
import '../models/bridge_peer_event.dart';
import '../models/wifi_endpoint.dart';
import '../models/wifi_host_result.dart';

/// Abstraction for Wi-Fi discovery (mDNS) and data plane (HttpServer / WebSocket).
abstract class WifiTransport {
  /// Peer socket connect / disconnect events.
  Stream<BridgePeerEvent> get onPeerConnectionChanged;

  /// Host-side peers (pending + connected). Empty when not hosting.
  List<BridgePeer> get hostPeers;

  /// Start local WebSocket server and register mDNS service.
  ///
  /// WebSocket bind failures throw. mDNS register timeout / failure is reported
  /// in [WifiHostResult.mdnsError] without tearing down the server.
  ///
  /// When [requireConnectionApproval] is true, incoming Clients emit
  /// [BridgePeerEventType.connectionRequest] until [approvePeer] / [rejectPeer].
  Future<WifiHostResult> startHost({
    required String deviceName,
    required String serviceUuid,
    int? port,
    bool requireConnectionApproval = true,
  });

  /// Stop WebSocket server and unregister mDNS.
  Future<void> stopHost();

  /// Approve a pending Host peer (Wi-Fi).
  Future<void> approvePeer(String peerId);

  /// Reject a pending Host peer and close its socket.
  Future<void> rejectPeer(String peerId);

  /// Disconnect an approved (or pending) Host peer by id.
  Future<void> disconnectPeer(String peerId);

  /// Discover Hosts advertising [serviceUuid] over mDNS.
  ///
  /// Emits cumulative device lists (merged by the manager with BLE results).
  Stream<List<BridgeDevice>> scanHosts({required String serviceUuid});

  Future<void> stopScan();

  /// Connect to a Host over WebSocket.
  Future<void> connect(WifiEndpoint endpoint);

  Future<void> disconnect();

  Future<void> sendMessage(Map<String, dynamic> data);

  Stream<Map<String, dynamic>> get onMessageReceived;

  Future<void> dispose();
}
