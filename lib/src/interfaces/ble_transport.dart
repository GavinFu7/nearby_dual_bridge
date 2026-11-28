import '../models/ble_endpoint.dart';
import '../models/bridge_device.dart';
import '../models/bridge_peer.dart';
import '../models/bridge_peer_event.dart';

/// Abstraction for BLE dual-role transport (Peripheral Host + Central Client).
abstract class BleTransport {
  /// Peer BLE link connect / disconnect events.
  Stream<BridgePeerEvent> get onPeerConnectionChanged;

  /// Host-side peers (pending + connected). Empty when not hosting.
  List<BridgePeer> get hostPeers;

  /// Start GATT service + advertising as Peripheral (Host).
  ///
  /// When [requireConnectionApproval] is true, centrals that enable notify emit
  /// [BridgePeerEventType.connectionRequest] until [approvePeer] / [rejectPeer].
  Future<void> startHost({
    required String deviceName,
    required String serviceUuid,
    bool requireConnectionApproval = true,
  });

  /// Stop advertising and tear down GATT services.
  Future<void> stopHost();

  /// Approve a pending Host peer (BLE central).
  Future<void> approvePeer(String peerId);

  /// Reject a pending Host peer.
  ///
  /// On Android the GATT link is disconnected when possible; on Apple platforms
  /// the peripheral cannot force-disconnect, so the peer is only logically rejected
  /// (writes ignored / notifies stopped).
  Future<void> rejectPeer(String peerId);

  /// Disconnect / kick an approved (or pending) Host peer by id.
  Future<void> disconnectPeer(String peerId);

  /// Scan for Peripherals advertising [serviceUuid].
  Stream<List<BridgeDevice>> scanHosts({required String serviceUuid});

  Future<void> stopScan();

  /// Hint from the manager: correlation codes already visible over Wi-Fi.
  ///
  /// Implementations may skip GATT name resolve for matching BLE sightings.
  void updateWifiMatchedCorrelationCodes(Set<String> codes) {}

  /// Connect as Central to a discovered Peripheral.
  Future<void> connect(
    BleEndpoint endpoint, {
    String? serviceUuid,
  });

  Future<void> disconnect();

  /// Send a full logical message (implementation must chunk if needed).
  Future<void> sendMessage(Map<String, dynamic> data);

  Stream<Map<String, dynamic>> get onMessageReceived;

  Future<void> dispose();
}
