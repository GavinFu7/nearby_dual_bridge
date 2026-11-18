import 'ble_endpoint.dart';
import 'wifi_endpoint.dart';

/// A nearby Host discovered via mDNS and/or BLE, merged into one logical device.
///
/// Merge key is typically [serviceUuid] + [correlationCode] (8-char Host prefix).
class BridgeDevice {
  const BridgeDevice({
    required this.id,
    required this.name,
    required this.serviceUuid,
    this.correlationCode,
    this.nameResolved = true,
    this.wifi,
    this.ble,
    this.lastSeen,
  });

  /// Stable identifier used to merge Wi-Fi and BLE sightings of the same Host.
  final String id;

  /// Human-readable device name (correlation prefix already stripped).
  final String name;

  /// Application service UUID used to filter Hosts of the same app/session.
  final String serviceUuid;

  /// Hidden 8-char Host prefix shared by Wi-Fi and BLE of the same session.
  ///
  /// Not shown in UI; used only to correlate dual-transport sightings.
  final String? correlationCode;

  /// Whether [name] is known (Wi-Fi TXT / mDNS, or BLE GATT resolve).
  ///
  /// BLE advertise alone only carries [correlationCode]; until resolve (or a
  /// matching Wi-Fi sighting), the device should stay hidden from the scan UI.
  final bool nameResolved;

  /// Present when the Host was seen (or resolved) over Wi-Fi / mDNS.
  final WifiEndpoint? wifi;

  /// Present when the Host was seen over BLE advertising.
  final BleEndpoint? ble;

  /// Last time either transport reported this device.
  final DateTime? lastSeen;

  bool get supportsWifi => wifi != null;

  bool get supportsBle => ble != null;

  bool get isDualTransport => supportsWifi && supportsBle;

  /// Ready to show in Client scan results.
  bool get isVisibleInScan =>
      supportsWifi || (nameResolved && name.trim().isNotEmpty);

  BridgeDevice copyWith({
    String? id,
    String? name,
    String? serviceUuid,
    String? correlationCode,
    bool? nameResolved,
    WifiEndpoint? wifi,
    BleEndpoint? ble,
    DateTime? lastSeen,
    bool clearWifi = false,
    bool clearBle = false,
    bool clearCorrelationCode = false,
  }) {
    return BridgeDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      serviceUuid: serviceUuid ?? this.serviceUuid,
      correlationCode: clearCorrelationCode
          ? null
          : (correlationCode ?? this.correlationCode),
      nameResolved: nameResolved ?? this.nameResolved,
      wifi: clearWifi ? null : (wifi ?? this.wifi),
      ble: clearBle ? null : (ble ?? this.ble),
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// Merge another sighting of the same logical device (same [id]).
  BridgeDevice merge(BridgeDevice other) {
    assert(id == other.id, 'Cannot merge devices with different ids');
    final preferWifiName = supportsWifi || other.supportsWifi;
    final mergedName = preferWifiName
        ? (wifi != null ? name : other.name)
        : (other.name.isNotEmpty ? other.name : name);
    return BridgeDevice(
      id: id,
      name: mergedName.isNotEmpty ? mergedName : name,
      serviceUuid: serviceUuid,
      correlationCode: other.correlationCode ?? correlationCode,
      nameResolved: nameResolved || other.nameResolved || preferWifiName,
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
      'BridgeDevice(id: $id, name: $name, code: $correlationCode, '
      'wifi: $supportsWifi, ble: $supportsBle)';

  @override
  bool operator ==(Object other) {
    return other is BridgeDevice &&
        other.id == id &&
        other.name == name &&
        other.serviceUuid == serviceUuid &&
        other.correlationCode == correlationCode &&
        other.nameResolved == nameResolved &&
        other.wifi?.host == wifi?.host &&
        other.wifi?.port == wifi?.port &&
        other.ble?.peripheralId == ble?.peripheralId;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        serviceUuid,
        correlationCode,
        nameResolved,
        wifi?.host,
        wifi?.port,
        ble?.peripheralId,
      );
}
