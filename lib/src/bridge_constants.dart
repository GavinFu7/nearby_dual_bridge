import 'dart:convert';
import 'dart:math';
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

  /// Readable GATT characteristic carrying the full Host device name
  /// (`correlationCode` + display name).
  ///
  /// Used because Apple BLE advertisements often truncate / omit Local Name
  /// when a 128-bit service UUID is present. Advertise Local Name carries only
  /// the 8-char [correlationCodeLength] code.
  static const String deviceNameCharacteristicUuid =
      'a1b2c3d2-e5f6-4789-abcd-ef0123456789';

  /// Length of the hidden correlation prefix prepended to [deviceName].
  static const int correlationCodeLength = 8;

  /// Alphabet used for Host correlation codes (fits BLE Local Name limits).
  static const String correlationCodeAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// mDNS TXT key for the application service UUID.
  static const String txtUuidKey = 'uuid';

  /// mDNS TXT key for the wire device name (`code` + display name).
  static const String txtNameKey = 'name';

  /// Stable merge id: `serviceUuid|correlationCode` (or fallback name).
  static String deviceId({
    required String serviceUuid,
    required String correlationCode,
  }) =>
      '${serviceUuid.trim().toLowerCase()}|${correlationCode.trim().toLowerCase()}';

  /// Stable BLE sighting id (peripheral-scoped; merge uses [correlationCode]).
  static String bleDeviceId({
    required String serviceUuid,
    required String peripheralId,
  }) =>
      '${serviceUuid.trim().toLowerCase()}|ble|${peripheralId.trim().toLowerCase()}';

  /// Random 8-char code prepended to Host `deviceName` (not shown in UI).
  static String generateCorrelationCode([Random? random]) {
    final rng = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < correlationCodeLength; i++) {
      buffer.write(
        correlationCodeAlphabet[rng.nextInt(correlationCodeAlphabet.length)],
      );
    }
    return buffer.toString();
  }

  /// Wire name: `[8-char code][displayName]`.
  static String encodeDeviceName({
    required String correlationCode,
    required String displayName,
  }) {
    final code = correlationCode.trim();
    if (!isCorrelationCode(code)) {
      throw ArgumentError.value(
        correlationCode,
        'correlationCode',
        'Must be $correlationCodeLength alphanumeric characters',
      );
    }
    final display = displayName.trim().isEmpty ? 'NDB' : displayName.trim();
    return '$code$display';
  }

  /// Parse a wire / advertise name into code + display name.
  ///
  /// Returns `null` when the value does not start with a valid correlation code
  /// (legacy hosts without a prefix).
  static ({String code, String displayName})? parseDeviceName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length < correlationCodeLength) return null;
    final code = trimmed.substring(0, correlationCodeLength);
    if (!isCorrelationCode(code)) return null;
    return (
      code: code,
      displayName: trimmed.substring(correlationCodeLength),
    );
  }

  static bool isCorrelationCode(String value) {
    if (value.length != correlationCodeLength) return false;
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      final isUpper = c >= 65 && c <= 90;
      final isLower = c >= 97 && c <= 122;
      final isDigit = c >= 48 && c <= 57;
      if (!isUpper && !isLower && !isDigit) return false;
    }
    return true;
  }

  /// Display-facing name with the hidden correlation prefix removed.
  static String displayNameOf(String raw) {
    final parsed = parseDeviceName(raw);
    if (parsed == null) return raw.trim();
    final display = parsed.displayName.trim();
    return display.isEmpty ? raw.trim() : display;
  }

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
