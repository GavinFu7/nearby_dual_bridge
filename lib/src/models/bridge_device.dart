import 'ble_endpoint.dart';
import 'wifi_endpoint.dart';

/// A nearby Host discovered via mDNS and/or BLE, merged into one logical device.
///
/// Merge key is typically [serviceUuid] + [name] (or a Host-advertised instance id
/// once the Wi-Fi / BLE modules are implemented).
class BridgeDevice {
  const BridgeDevice({
    required this.id,
    required this.name,
    required this.serviceUuid,
    this.wifi,
    this.ble,
    this.lastSeen,
  });

  /// Stable identifier used to merge Wi-Fi and BLE sightings of the same Host.
  final String id;

  /// Human-readable device name advertised by the Host.
  final String name;

  /// Application service UUID used to filter Hosts of the same app/session.
  final String serviceUuid;

  /// Present when the Host was seen (or resolved) over Wi-Fi / mDNS.
  final WifiEndpoint? wifi;

  /// Present when the Host was seen over BLE advertising.
  final BleEndpoint? ble;

  /// Last time either transport reported this device.
  final DateTime? lastSeen;

  bool get supportsWifi => wifi != null;

  bool get supportsBle => ble != null;

  bool get isDualTransport => supportsWifi && supportsBle;

  BridgeDevice copyWith({
    String? id,
    String? name,
    String? serviceUuid,
    WifiEndpoint? wifi,
    BleEndpoint? ble,
    DateTime? lastSeen,
    bool clearWifi = false,
    bool clearBle = false,
  }) {
    return BridgeDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      serviceUuid: serviceUuid ?? this.serviceUuid,
      wifi: clearWifi ? null : (wifi ?? this.wifi),
      ble: clearBle ? null : (ble ?? this.ble),
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// Merge another sighting of the same logical device (same [id]).
  BridgeDevice merge(BridgeDevice other) {
    assert(id == other.id, 'Cannot merge devices with different ids');
    return BridgeDevice(
      id: id,
      name: other.name.isNotEmpty ? other.name : name,
      serviceUuid: serviceUuid,
      wifi: other.wifi ?? wifi,
      ble: other.ble ?? ble,
      lastSeen: _later(lastSeen, other.lastSeen),
    );
  }

  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  @override
  String toString() =>
      'BridgeDevice(id: $id, name: $name, wifi: $supportsWifi, ble: $supportsBle)';

  @override
  bool operator ==(Object other) {
    return other is BridgeDevice &&
        other.id == id &&
        other.name == name &&
        other.serviceUuid == serviceUuid &&
        other.wifi?.host == wifi?.host &&
        other.wifi?.port == wifi?.port &&
        other.ble?.peripheralId == ble?.peripheralId;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        serviceUuid,
        wifi?.host,
        wifi?.port,
        ble?.peripheralId,
      );
}
