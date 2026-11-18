import 'models/bridge_device.dart';

/// Updates Wi-Fi-loss suppression for dual-transport Hosts during continuous scan.
///
/// Once a Host was seen on Wi-Fi, losing Wi-Fi hides BLE-only leftovers for that
/// key. When both Wi-Fi and BLE are gone, suppression clears so a later
/// rediscovery can show again under normal rules.
void updateWifiLossBleSuppression({
  required Set<String> seenWithWifiKeys,
  required Set<String> suppressBleOnlyKeys,
  required Iterable<String> wifiKeys,
  required Iterable<String> bleKeys,
}) {
  final wifi = wifiKeys.toSet();
  final ble = bleKeys.toSet();

  for (final key in wifi) {
    seenWithWifiKeys.add(key);
    suppressBleOnlyKeys.remove(key);
  }

  for (final key in seenWithWifiKeys) {
    if (!wifi.contains(key)) {
      suppressBleOnlyKeys.add(key);
    }
  }

  // Both transports gone ⇒ allow a future rediscovery to surface again.
  suppressBleOnlyKeys.removeWhere(
    (key) => !wifi.contains(key) && !ble.contains(key),
  );
}

/// Merge Wi-Fi + BLE scan snapshots by hidden [BridgeDevice.correlationCode].
///
/// Same code ⇒ one logical Host (prefer Wi-Fi display name). BLE-only rows
/// stay hidden until GATT name resolve fills [BridgeDevice.name], and are also
/// suppressed after a prior Wi-Fi sighting disappears ([suppressBleOnlyKeys]).
List<BridgeDevice> mergeWifiBleScanSnapshots({
  required List<BridgeDevice> wifiDevices,
  required List<BridgeDevice> bleDevices,
  Set<String> suppressBleOnlyKeys = const {},
}) {
  final result = <String, BridgeDevice>{};

  for (final wifi in wifiDevices) {
    result[scanMergeKey(wifi)] = wifi;
  }

  for (final ble in bleDevices) {
    final key = scanMergeKey(ble);
    final existing = result[key];
    if (existing != null) {
      result[key] = existing.merge(
        ble.copyWith(
          id: existing.id,
          name: existing.name,
          nameResolved: true,
        ),
      );
      continue;
    }

    if (suppressBleOnlyKeys.contains(key)) continue;
    if (!ble.isVisibleInScan) continue;
    result[key] = ble;
  }

  final list = result.values
      .where((device) => device.isVisibleInScan)
      .toList(growable: false);
  list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}

String scanMergeKey(BridgeDevice device) {
  final code = device.correlationCode?.trim().toLowerCase();
  if (code != null && code.isNotEmpty) {
    return '${device.serviceUuid.trim().toLowerCase()}|$code';
  }
  return device.id;
}
