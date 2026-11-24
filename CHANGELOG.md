## 0.0.5

* Declare supported platforms explicitly as Android, iOS, macOS, and Windows in `pubspec.yaml` (auto-detect had dropped macOS because `permission_handler` has no macOS entry).

## 0.0.3

* Skip BLE GATT name resolve when Wi-Fi already matched the same correlation code (or the name was resolved earlier).
* Throttle BLE scan emissions (significant changes immediate; RSSI-only updates coalesced) to reduce UI churn.
* Fix Wi-Fi mDNS `ServiceListener` cleanup on stop scan.
* Replace name-resolve busy-wait polling with a `Future`-based idle wait.

## 0.0.2

* Prefix Host `deviceName` with a hidden 8-char correlation code; merge Wi-Fi / BLE by that code and prefer the Wi-Fi display name when both match.
* BLE advertise Local Name uses the correlation code only; full `code + name` is exposed on a readable GATT characteristic.
* During Client BLE scan, auto-connect to resolve the full name before showing BLE-only Hosts; scan list keeps updating until `stopScan`.
* Hide BLE leftovers when a previously seen Wi-Fi Host drops from the scan list, until the device is rediscovered.
* Harden `stopHost` so BLE advertising / GATT services are always torn down; BLE scan entries expire after advertisements stop.
* Example: connected Host row shows **Disconnect** instead of **Connect**.

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
