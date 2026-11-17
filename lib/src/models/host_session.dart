import 'wifi_endpoint.dart';

/// Result of [DualBridgeManager.startHost].
class HostSession {
  const HostSession({
    required this.wifi,
    required this.bleAdvertising,
    this.bleError,
  });

  /// Local WebSocket endpoint registered via mDNS.
  final WifiEndpoint wifi;

  /// Whether BLE Peripheral advertising started successfully.
  final bool bleAdvertising;

  /// Populated when BLE advertise failed but Wi-Fi Host is still running.
  final Object? bleError;

  bool get isFullyReady => bleAdvertising && bleError == null;
}
