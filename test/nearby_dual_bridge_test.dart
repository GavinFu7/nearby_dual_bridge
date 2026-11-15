import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge_platform_interface.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockNearbyDualBridgePlatform
    with MockPlatformInterfaceMixin
    implements NearbyDualBridgePlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final NearbyDualBridgePlatform initialPlatform = NearbyDualBridgePlatform.instance;

  test('$MethodChannelNearbyDualBridge is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelNearbyDualBridge>());
  });

  test('getPlatformVersion', () async {
    NearbyDualBridge nearbyDualBridgePlugin = NearbyDualBridge();
    MockNearbyDualBridgePlatform fakePlatform = MockNearbyDualBridgePlatform();
    NearbyDualBridgePlatform.instance = fakePlatform;

    expect(await nearbyDualBridgePlugin.getPlatformVersion(), '42');
  });
}
