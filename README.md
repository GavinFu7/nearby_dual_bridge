# nearby_dual_bridge

Cross-platform dual-role nearby bridge for **Android**, **iOS**, and **macOS**.

Each device can dynamically act as **Host** (server / controlled) or **Client** (controller) over:

- **Wi-Fi**: mDNS (`nsd`) + WebSocket (`dart:io`)
- **BLE**: Peripheral + Central (`bluetooth_low_energy`)

## Quick start

```dart
final bridge = DualBridgeManager();

// Optional: watch connect / disconnect (including unexpected drops)
bridge.addStatusListener((status) {
  print(status); // role, connectionState, peerCount, reason
});

final session = await bridge.startHost(
  deviceName: 'MacHost', // keep short (≤8) for Apple BLE Local Name
  serviceUuid: BridgeConstants.defaultServiceUuid,
);
print('Listening on ${session.wifi.host}:${session.wifi.port}');

bridge
    .scanHosts(
      serviceUuid: BridgeConstants.defaultServiceUuid,
      wifi: true,
      ble: true,
    )
    .listen((devices) {
  // merged Wi-Fi + BLE sightings
});

await bridge.connect(
  device,
  preference: ConnectionPreference.preferWifi, // or preferBle / wifiOnly / bleOnly
);
await bridge.sendMessage({'type': 'ping'});
bridge.onMessageReceived.listen(print);

await bridge.disconnect();
await bridge.stopHost();
```

## Example

```bash
cd example
flutter run -d <device>
```

Use two physical devices on the same Wi-Fi (BLE does not work on emulators).

See [example/README.md](example/README.md) for Host/Client steps and platform permission notes.

## Platform setup (host app)

Consumers must declare platform permissions. The `example/` app already includes them.

**Android** — `BLUETOOTH_SCAN` / `ADVERTISE` / `CONNECT`, location (older APIs), `CHANGE_WIFI_MULTICAST_STATE`, `INTERNET`; `minSdk` 24+.

**iOS / macOS** — `NSBluetoothAlwaysUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_ndb._tcp`); macOS also needs network + bluetooth entitlements.

## Defaults

| Item | Value |
| --- | --- |
| mDNS type | `_ndb._tcp` |
| Default service UUID | `a1b2c3d0-e5f6-4789-abcd-ef0123456789` |
| Message GATT characteristic | `a1b2c3d1-e5f6-4789-abcd-ef0123456789` |
| Device merge key | `serviceUuid\|deviceName` (case-insensitive) |
| Connect default | Prefer Wi-Fi, fall back to BLE |

## Notes

- Keep Host `deviceName` short on Apple platforms so BLE advertising still includes a Local Name.
- WebSocket connect prefers mDNS hostname / IPv4 (link-local IPv6 is skipped).
- `addStatusListener` / `onStatusChanged` report `peer_connected` and `peer_disconnected` for both Host and Client.

## Dependencies

| Package | Version | Role |
| --- | --- | --- |
| `nsd` | ^5.0.1 | mDNS register / discover |
| `bluetooth_low_energy` | ^6.2.1 | BLE Central + Peripheral |
| `permission_handler` | ^13.0.2 | Android runtime permissions |
| `dart:io` | SDK | `HttpServer` / `WebSocket` |
