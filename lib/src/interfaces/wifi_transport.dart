import '../models/bridge_device.dart';
import '../models/bridge_peer_event.dart';
import '../models/wifi_endpoint.dart';
import '../models/wifi_host_result.dart';

/// Abstraction for Wi-Fi discovery (mDNS) and data plane (HttpServer / WebSocket).
abstract class WifiTransport {
  /// Peer socket connect / disconnect events.
  Stream<BridgePeerEvent> get onPeerConnectionChanged;

  /// Start local WebSocket server and register mDNS service.
  ///
  /// WebSocket bind failures throw. mDNS register timeout / failure is reported
  /// in [WifiHostResult.mdnsError] without tearing down the server.
  Future<WifiHostResult> startHost({
    required String deviceName,
    required String serviceUuid,
    int? port,
  });

  /// Stop WebSocket server and unregister mDNS.
  Future<void> stopHost();

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
