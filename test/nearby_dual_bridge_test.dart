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
      id: 'dev-1',
      name: 'TV',
      serviceUuid: 'uuid',
      wifi: const WifiEndpoint(host: 'tv.local', port: 8787),
    );
    final bleOnly = BridgeDevice(
      id: 'dev-1',
      name: 'TV',
      serviceUuid: 'uuid',
      ble: const BleEndpoint(peripheralId: 'AA:BB', rssi: -50),
    );

    final merged = wifiOnly.merge(bleOnly);
    expect(merged.supportsWifi, isTrue);
    expect(merged.supportsBle, isTrue);
    expect(merged.isDualTransport, isTrue);
    expect(merged.ble?.rssi, -50);
  });

  test('BridgeConstants builds stable device ids', () {
    expect(
      BridgeConstants.deviceId(serviceUuid: 'ABC', name: ' Living-Room '),
      'abc|living-room',
    );
  });
}
