/// Runtime role of the local device.
enum BridgeRole {
  /// Idle — neither hosting nor connected as a client.
  idle,

  /// Host (server / controlled device): advertises via mDNS + BLE Peripheral.
  host,

  /// Client (controller): discovers and connects to a Host.
  client,
}
