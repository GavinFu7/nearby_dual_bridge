import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge.dart';

void main() {
  test('DualBridgeManager starts idle and disconnected', () {
    final bridge = DualBridgeManager();
    expect(bridge.role, BridgeRole.idle);
    expect(bridge.connectionState, BridgeConnectionState.disconnected);
    expect(bridge.activeTransport, isNull);
  });

  test('BridgeDevice merges wifi and ble endpoints', () {
    final wifiOnly = BridgeDevice(
      id: 'uuid|ab12cd34',
      name: 'TV',
      serviceUuid: 'uuid',
      correlationCode: 'Ab12Cd34',
      wifi: const WifiEndpoint(host: 'tv.local', port: 8787),
    );
    final bleOnly = BridgeDevice(
      id: 'uuid|ab12cd34',
      name: '',
      serviceUuid: 'uuid',
      correlationCode: 'Ab12Cd34',
      nameResolved: false,
      ble: const BleEndpoint(peripheralId: 'AA:BB', rssi: -50),
    );

    final merged = wifiOnly.merge(bleOnly);
    expect(merged.supportsWifi, isTrue);
    expect(merged.supportsBle, isTrue);
    expect(merged.isDualTransport, isTrue);
    expect(merged.name, 'TV');
    expect(merged.ble?.rssi, -50);
    expect(merged.isVisibleInScan, isTrue);
  });

  test('BLE-only unresolved devices stay hidden', () {
    final bleOnly = BridgeDevice(
      id: 'uuid|ab12cd34',
      name: '',
      serviceUuid: 'uuid',
      correlationCode: 'Ab12Cd34',
      nameResolved: false,
      ble: const BleEndpoint(peripheralId: 'AA:BB', rssi: -50),
    );
    expect(bleOnly.isVisibleInScan, isFalse);

    final resolved = bleOnly.copyWith(name: 'Phone', nameResolved: true);
    expect(resolved.isVisibleInScan, isTrue);
  });

  test('BridgeConstants encodes and parses correlation names', () {
    final code = BridgeConstants.generateCorrelationCode();
    expect(code.length, BridgeConstants.correlationCodeLength);
    expect(BridgeConstants.isCorrelationCode(code), isTrue);

    final wire = BridgeConstants.encodeDeviceName(
      correlationCode: code,
      displayName: 'MacHost',
    );
    expect(wire, '$code${'MacHost'}');

    final parsed = BridgeConstants.parseDeviceName(wire);
    expect(parsed?.code, code);
    expect(parsed?.displayName, 'MacHost');
    expect(BridgeConstants.displayNameOf(wire), 'MacHost');

    final advertiseOnly = BridgeConstants.parseDeviceName(code);
    expect(advertiseOnly?.code, code);
    expect(advertiseOnly?.displayName, isEmpty);
  });

  test('BridgeConstants builds stable device ids', () {
    expect(
      BridgeConstants.deviceId(
        serviceUuid: 'ABC',
        correlationCode: ' Ab12Cd34 ',
      ),
      'abc|ab12cd34',
    );
    expect(
      BridgeConstants.bleDeviceId(
        serviceUuid: 'ABC',
        peripheralId: ' AA-BB ',
      ),
      'abc|ble|aa-bb',
    );
  });
}
