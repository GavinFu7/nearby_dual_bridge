# nearby_dual_bridge example

Demonstrates Host / Client dual-role nearby communication over **Wi-Fi** (mDNS + WebSocket) and **BLE**.

## Run

```bash
cd example
flutter run -d <device>
```

Use two physical devices (or one macOS + one phone) on the same Wi-Fi for discovery.

1. Device A: set a name → **Start Host**
2. Device B: same Service UUID → **Scan Hosts** → **Connect**
3. Send chat messages either way

## Platform notes

- Android / iOS / macOS permissions are already wired in this example.
- BLE does not work on emulators; use real hardware.
- Keep Service UUID identical on both sides (default is filled in).
