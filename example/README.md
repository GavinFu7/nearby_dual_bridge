# nearby_dual_bridge example

Demonstrates Host / Client dual-role nearby communication over **Wi-Fi** (mDNS + WebSocket) and **BLE**.

## Run

```bash
cd example
flutter run -d <device>
```

Use two physical devices (for example macOS + iPhone/iPad) on the same Wi-Fi.

1. Device A: enter a display name (e.g. `MacHost`) → **Start Host**
2. Device B: same Service UUID → **Scan Both** (or Wi-Fi / BLE only) → **Connect**
3. Optionally set **Connection preference** before Connect
4. Send chat messages either way; Log shows `peer_disconnected` if the other side drops

## Platform notes

- Android / iOS / macOS permissions are already wired in this example.
- iOS/iPad: enable **Settings → Privacy → Local Network** for this app.
- BLE does not work on emulators; use real hardware.
- Keep Service UUID identical on both sides (default is filled in).
- Host names can be long; an 8-char correlation code is added automatically for Wi-Fi/BLE pairing.
