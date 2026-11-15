import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nearby_dual_bridge_platform_interface.dart';

/// An implementation of [NearbyDualBridgePlatform] that uses method channels.
class MethodChannelNearbyDualBridge extends NearbyDualBridgePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('nearby_dual_bridge');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
