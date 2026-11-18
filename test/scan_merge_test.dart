import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge.dart';
import 'package:nearby_dual_bridge/src/scan_merge.dart';

void main() {
  BridgeDevice wifi(String code, String name) => BridgeDevice(
        id: 'uuid|${code.toLowerCase()}',
        name: name,
        serviceUuid: 'uuid',
        correlationCode: code,
        wifi: const WifiEndpoint(host: 'host.local', port: 8787),
      );

  BridgeDevice ble(String code, {required bool resolved, String name = ''}) =>
      BridgeDevice(
        id: 'uuid|${code.toLowerCase()}',
        name: name,
        serviceUuid: 'uuid',
        correlationCode: code,
        nameResolved: resolved,
        ble: const BleEndpoint(peripheralId: 'aa', rssi: -40),
      );

  test('dual transport prefers wifi name', () {
    final merged = mergeWifiBleScanSnapshots(
      wifiDevices: [wifi('Ab12Cd34', 'MacHost')],
      bleDevices: [ble('Ab12Cd34', resolved: false)],
    );
    expect(merged, hasLength(1));
    expect(merged.single.name, 'MacHost');
    expect(merged.single.isDualTransport, isTrue);
  });

  test('wifi loss hides leftover ble until both are gone then rediscovered', () {
    final seenWithWifi = <String>{};
    final suppress = <String>{};
    const code = 'Ab12Cd34';
    final key = 'uuid|ab12cd34';

    // Seen on both.
    updateWifiLossBleSuppression(
      seenWithWifiKeys: seenWithWifi,
      suppressBleOnlyKeys: suppress,
      wifiKeys: [key],
      bleKeys: [key],
    );
    var list = mergeWifiBleScanSnapshots(
      wifiDevices: [wifi(code, 'MacHost')],
      bleDevices: [ble(code, resolved: true, name: 'MacHost')],
      suppressBleOnlyKeys: suppress,
    );
    expect(list, hasLength(1));

    // Wi-Fi disappears → suppress BLE leftover.
    updateWifiLossBleSuppression(
      seenWithWifiKeys: seenWithWifi,
      suppressBleOnlyKeys: suppress,
      wifiKeys: const [],
      bleKeys: [key],
    );
    expect(suppress, contains(key));
    list = mergeWifiBleScanSnapshots(
      wifiDevices: const [],
      bleDevices: [ble(code, resolved: true, name: 'MacHost')],
      suppressBleOnlyKeys: suppress,
    );
    expect(list, isEmpty);

    // Both gone → clear suppress.
    updateWifiLossBleSuppression(
      seenWithWifiKeys: seenWithWifi,
      suppressBleOnlyKeys: suppress,
      wifiKeys: const [],
      bleKeys: const [],
    );
    expect(suppress, isEmpty);

    // Later BLE-only rediscovery (resolved) can show again.
    list = mergeWifiBleScanSnapshots(
      wifiDevices: const [],
      bleDevices: [ble(code, resolved: true, name: 'MacHost')],
      suppressBleOnlyKeys: suppress,
    );
    expect(list, hasLength(1));
    expect(list.single.supportsBle, isTrue);
    expect(list.single.supportsWifi, isFalse);
  });

  test('wifi return clears suppression and shows again', () {
    final seenWithWifi = <String>{};
    final suppress = <String>{};
    const code = 'Ab12Cd34';
    final key = 'uuid|ab12cd34';

    updateWifiLossBleSuppression(
      seenWithWifiKeys: seenWithWifi,
      suppressBleOnlyKeys: suppress,
      wifiKeys: [key],
      bleKeys: [key],
    );
    updateWifiLossBleSuppression(
      seenWithWifiKeys: seenWithWifi,
      suppressBleOnlyKeys: suppress,
      wifiKeys: const [],
      bleKeys: [key],
    );
    expect(suppress, contains(key));

    updateWifiLossBleSuppression(
      seenWithWifiKeys: seenWithWifi,
      suppressBleOnlyKeys: suppress,
      wifiKeys: [key],
      bleKeys: [key],
    );
    expect(suppress, isEmpty);

    final list = mergeWifiBleScanSnapshots(
      wifiDevices: [wifi(code, 'MacHost')],
      bleDevices: [ble(code, resolved: false)],
      suppressBleOnlyKeys: suppress,
    );
    expect(list, hasLength(1));
    expect(list.single.name, 'MacHost');
  });
}
