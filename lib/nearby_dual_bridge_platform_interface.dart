import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'nearby_dual_bridge_method_channel.dart';

abstract class NearbyDualBridgePlatform extends PlatformInterface {
  /// Constructs a NearbyDualBridgePlatform.
  NearbyDualBridgePlatform() : super(token: _token);

  static final Object _token = Object();

  static NearbyDualBridgePlatform _instance = MethodChannelNearbyDualBridge();

  /// The default instance of [NearbyDualBridgePlatform] to use.
  ///
  /// Defaults to [MethodChannelNearbyDualBridge].
  static NearbyDualBridgePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NearbyDualBridgePlatform] when
  /// they register themselves.
  static set instance(NearbyDualBridgePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
