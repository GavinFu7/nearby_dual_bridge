## 0.0.2

## 0.0.1

* Initial release of `nearby_dual_bridge` for Android, iOS, and macOS.
* Add `DualBridgeManager` unified Host / Client API over Wi-Fi and BLE.
* Add `DualBridgeManager.addStatusListener` / `onStatusChanged` with peer connect/disconnect detection on Wi-Fi and BLE.
* Wi-Fi: mDNS register/discover via `nsd`, data plane via `dart:io` WebSocket.
* BLE: dual-role Central / Peripheral via `bluetooth_low_energy`, with chunked JSON framing.
* Merge discovered Hosts that expose both Wi-Fi and BLE endpoints into one `BridgeDevice`.
* Connection preference: prefer Wi-Fi (default), prefer BLE, or force a single transport.
* Example app with Host / Client controls, Wi-Fi-only / BLE-only scan, and platform permissions.
* Ship as a Flutter package (no native plugin / `getPlatformVersion` method channel).
* Prefix Host `deviceName` with a hidden 8-char correlation code; merge Wi-Fi/BLE by that code and show the Wi-Fi display name when both match.
* BLE advertise uses the correlation code only; scan auto-connects to read the full name characteristic before showing BLE-only Hosts; scan list keeps updating until `stopScan`.