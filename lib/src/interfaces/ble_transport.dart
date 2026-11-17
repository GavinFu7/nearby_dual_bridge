import '../models/ble_endpoint.dart';
import '../models/bridge_device.dart';

/// Abstraction for BLE dual-role transport (Peripheral Host + Central Client).
///
/// Concrete implementation will use `bluetooth_low_energy` in a later phase.
abstract class BleTransport {
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
