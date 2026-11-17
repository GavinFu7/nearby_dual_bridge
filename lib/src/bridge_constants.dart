import 'dart:convert';
import 'dart:typed_data';

/// Shared protocol constants for mDNS + BLE.
abstract final class BridgeConstants {
  /// DNS-SD / Bonjour service type (must match Info.plist NSBonjourServices).
  static const String mdnsServiceType = '_ndb._tcp';

  /// Default GATT / app service UUID used by the example.
  static const String defaultServiceUuid =
      'a1b2c3d0-e5f6-4789-abcd-ef0123456789';

  /// GATT characteristic used for bidirectional JSON (chunked over BLE).
  static const String messageCharacteristicUuid =
      'a1b2c3d1-e5f6-4789-abcd-ef0123456789';

  /// mDNS TXT key for the application service UUID.
  static const String txtUuidKey = 'uuid';

  /// mDNS TXT key for the human-readable device name.
  static const String txtNameKey = 'name';

  static String deviceId({
    required String serviceUuid,
    required String name,
  }) =>
      '${serviceUuid.trim().toLowerCase()}|${name.trim().toLowerCase()}';

  static Map<String, Uint8List?> mdnsTxt({
    required String serviceUuid,
    required String deviceName,
  }) {
    return {
      txtUuidKey: Uint8List.fromList(utf8.encode(serviceUuid)),
      txtNameKey: Uint8List.fromList(utf8.encode(deviceName)),
    };
  }

  static String? txtString(Map<String, Uint8List?>? txt, String key) {
    final value = txt?[key];
    if (value == null || value.isEmpty) return null;
    return utf8.decode(value);
  }
}
