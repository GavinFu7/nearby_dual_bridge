/// Platform permission / authorization helper used before scan or advertise.
///
/// Android: BLUETOOTH_SCAN / CONNECT / ADVERTISE (+ location on older APIs).
/// Apple: Info.plist + entitlements are host-app concerns; runtime prompts
/// are driven by the OS when BLE / local network APIs are first used.
abstract class BridgePermissions {
  /// Ensure permissions needed to scan (Client) are granted.
  Future<bool> ensureScanPermissions();

  /// Ensure permissions needed to advertise / host are granted.
  Future<bool> ensureHostPermissions();
}
