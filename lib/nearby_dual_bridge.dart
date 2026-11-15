
import 'nearby_dual_bridge_platform_interface.dart';

class NearbyDualBridge {
  Future<String?> getPlatformVersion() {
    return NearbyDualBridgePlatform.instance.getPlatformVersion();
  }
}
