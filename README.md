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
  deviceName: 'MacHost', // display name; an 8-char code is prepended automatically
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
  // merged Wi-Fi + BLE sightings (continuous until stopScan)
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
| Device-name GATT characteristic | `a1b2c3d2-e5f6-4789-abcd-ef0123456789` |
| Device merge key | `serviceUuid\|correlationCode` (8-char Host prefix) |
| Connect default | Prefer Wi-Fi, fall back to BLE |

## Discovery & naming

- Host `deviceName` is prefixed with a hidden **8-char correlation code** (not shown in UI).
- Matching codes merge Wi-Fi + BLE into one `BridgeDevice` and prefer the **Wi-Fi display name**.
- BLE advertise Local Name is the correlation code only (Apple payload limits). Full `code + name` is on the readable device-name GATT characteristic.
- Client scan keeps updating until `stopScan`. BLE-only Hosts are shown only after GATT name resolve (skipped when Wi-Fi already matched the same code).
- If a Host was seen on Wi-Fi and Wi-Fi later drops from the scan list, BLE leftovers for that Host are hidden until rediscovery.
- After remote `stopHost`, BLE advertisements stop and stale BLE scan rows expire (~6s without ads).
- BLE scan emissions are throttled: identity / name changes emit immediately; RSSI-only updates are coalesced.

## Notes

- WebSocket connect prefers mDNS hostname / IPv4 (link-local IPv6 is skipped).
- `addStatusListener` / `onStatusChanged` report `peer_connected` and `peer_disconnected` for both Host and Client.
- `stopHost` tears down Wi-Fi (mDNS + WebSocket server) and BLE advertising / GATT services.

## Dependencies

| Package | Version | Role |
| --- | --- | --- |
| `nsd` | ^5.0.1 | mDNS register / discover |
| `bluetooth_low_energy` | ^6.2.1 | BLE Central + Peripheral |
| `permission_handler` | ^13.0.2 | Android runtime permissions |
| `dart:io` | SDK | `HttpServer` / `WebSocket` |
