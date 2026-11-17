# nearby_dual_bridge

Cross-platform dual-role nearby bridge for **Android**, **iOS**, and **macOS**.

Each device can dynamically act as **Host** (server / controlled) or **Client** (controller) over:

- **Wi-Fi**: mDNS (`nsd`) + WebSocket (`dart:io`)
- **BLE**: Peripheral + Central (`bluetooth_low_energy`)

## Quick start

```dart
final bridge = DualBridgeManager();

await bridge.startHost(
  deviceName: 'LivingRoom-TV',
  serviceUuid: BridgeConstants.defaultServiceUuid,
);

bridge.scanHosts(serviceUuid: BridgeConstants.defaultServiceUuid).listen((devices) {
  // merged Wi-Fi + BLE sightings
});

await bridge.connect(device); // prefer Wi-Fi, fall back to BLE
await bridge.sendMessage({'type': 'ping'});
bridge.onMessageReceived.listen(print);
```

## Example

```bash
cd example
flutter run -d <device>
```

See [example/README.md](example/README.md) for Host/Client demo steps and platform notes.

## Dependencies

| Package | Version | Role |
| --- | --- | --- |
| `nsd` | ^5.0.1 | mDNS register / discover |
| `bluetooth_low_energy` | ^6.2.1 | BLE Central + Peripheral |
| `permission_handler` | ^13.0.2 | Android runtime permissions |
| `dart:io` | SDK | `HttpServer` / `WebSocket` |

## Defaults

- mDNS type: `_ndb._tcp`
- Default service UUID: `a1b2c3d0-e5f6-4789-abcd-ef0123456789`
- Device merge key: `serviceUuid|deviceName` (case-insensitive)
