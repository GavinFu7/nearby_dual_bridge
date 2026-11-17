/// BLE reachability info for a discovered Host (Peripheral).
class BleEndpoint {
  const BleEndpoint({
    required this.peripheralId,
    this.rssi,
    this.advertisedName,
  });

  /// Platform-specific peripheral identifier from `bluetooth_low_energy`.
  final String peripheralId;

  /// Last observed RSSI, if reported by the scanner.
  final int? rssi;

  /// Local name from the advertisement, if present.
  final String? advertisedName;

  BleEndpoint copyWith({
    String? peripheralId,
    int? rssi,
    String? advertisedName,
  }) {
    return BleEndpoint(
      peripheralId: peripheralId ?? this.peripheralId,
      rssi: rssi ?? this.rssi,
      advertisedName: advertisedName ?? this.advertisedName,
    );
  }

  @override
  String toString() =>
      'BleEndpoint(peripheralId: $peripheralId, rssi: $rssi, name: $advertisedName)';
}
