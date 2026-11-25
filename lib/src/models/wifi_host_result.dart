import 'wifi_endpoint.dart';

/// Result of [WifiTransport.startHost]: WebSocket endpoint + mDNS register status.
class WifiHostResult {
  const WifiHostResult({
    required this.endpoint,
    required this.mdnsRegistered,
    this.mdnsError,
  });

  /// Local WebSocket server endpoint (always started when Host succeeds).
  final WifiEndpoint endpoint;

  /// Whether Bonjour / mDNS `register` completed within the timeout.
  final bool mdnsRegistered;

  /// Populated when mDNS register timed out or failed; WebSocket Host is still up.
  ///
  /// On Apple platforms a timeout often means Local Network permission is denied
  /// or the prompt was dismissed — there is no direct permission query API.
  final Object? mdnsError;
}
