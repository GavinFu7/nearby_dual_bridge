import '../models/ble_endpoint.dart';
import '../models/bridge_device.dart';
import '../models/bridge_peer_event.dart';

/// Abstraction for BLE dual-role transport (Peripheral Host + Central Client).
abstract class BleTransport {
  /// Peer BLE link connect / disconnect events.
  Stream<BridgePeerEvent> get onPeerConnectionChanged;
  /// Start GATT service + advertising as Peripheral (Host).
  Future<void> startHost({
    required String deviceName,
    required String serviceUuid,
  });

  /// Stop advertising and tear down GATT services.
  Future<void> stopHost();

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
