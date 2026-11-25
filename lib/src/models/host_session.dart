import 'wifi_endpoint.dart';

/// Result of [DualBridgeManager.startHost].
class HostSession {
  const HostSession({
    required this.wifi,
    required this.mdnsRegistered,
    required this.bleAdvertising,
    this.mdnsError,
    this.bleError,
  });

  /// Local WebSocket endpoint (always started when Host succeeds).
  final WifiEndpoint wifi;

  /// Whether Bonjour / mDNS `register` completed within the timeout.
  final bool mdnsRegistered;

  /// Populated when mDNS register timed out or failed; WebSocket Host is still up.
  ///
  /// On Apple platforms a timeout often means Local Network permission is denied
  /// or the prompt was dismissed — there is no direct permission query API.
  final Object? mdnsError;

  /// Whether BLE Peripheral advertising started successfully.
  final bool bleAdvertising;

  /// Populated when BLE advertise failed but Wi-Fi Host is still running.
  final Object? bleError;

  bool get isFullyReady =>
      mdnsRegistered &&
      mdnsError == null &&
      bleAdvertising &&
      bleError == null;
}
