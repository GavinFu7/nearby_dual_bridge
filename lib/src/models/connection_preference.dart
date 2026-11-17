/// Preference when connecting to a [BridgeDevice] that may expose Wi-Fi and/or BLE.
enum ConnectionPreference {
  /// Prefer Wi-Fi when available; fall back to BLE. (default)
  preferWifi,

  /// Prefer BLE when available; fall back to Wi-Fi.
  preferBle,

  /// Require Wi-Fi; fail if the device has no Wi-Fi endpoint.
  wifiOnly,

  /// Require BLE; fail if the device has no BLE endpoint.
  bleOnly,
}
