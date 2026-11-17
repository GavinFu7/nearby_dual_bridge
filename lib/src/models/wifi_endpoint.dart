/// Wi-Fi / WebSocket reachability info for a discovered Host.
class WifiEndpoint {
  const WifiEndpoint({
    required this.host,
    required this.port,
    this.addresses = const [],
    this.serviceName,
  });

  /// Hostname from mDNS (preferred for Apple platforms).
  final String host;

  /// WebSocket / HttpServer listen port advertised by the Host.
  final int port;

  /// Optional resolved IP addresses (when mDNS IP lookup is enabled).
  final List<String> addresses;

  /// Raw mDNS service instance name, if available.
  final String? serviceName;

  /// Prefer mDNS hostname; Apple platforms resolve `.local` more reliably
  /// than raw link-local IPv6 addresses.
  Uri get webSocketUri => connectionCandidates.first;

  /// Ordered connection targets: hostname → IPv4 → (non-link-local) IPv6.
  List<Uri> get connectionCandidates {
    final seen = <String>{};
    final uris = <Uri>[];

    void addHost(String raw) {
      final normalized = _normalizeHost(raw);
      if (normalized.isEmpty || !seen.add(normalized)) return;
      uris.add(Uri(scheme: 'ws', host: normalized, port: port, path: '/'));
    }

    addHost(host);

    final ipv4 = <String>[];
    final ipv6 = <String>[];
    for (final address in addresses) {
      if (_isIpv4(address)) {
        ipv4.add(address);
      } else if (_isIpv6(address) && !_isLinkLocalIpv6(address)) {
        ipv6.add(address);
      }
    }
    for (final address in ipv4) {
      addHost(address);
    }
    for (final address in ipv6) {
      addHost(address);
    }

    if (uris.isEmpty) {
      addHost(host.isNotEmpty ? host : 'localhost');
    }
    return uris;
  }

  WifiEndpoint copyWith({
    String? host,
    int? port,
    List<String>? addresses,
    String? serviceName,
  }) {
    return WifiEndpoint(
      host: host ?? this.host,
      port: port ?? this.port,
      addresses: addresses ?? this.addresses,
      serviceName: serviceName ?? this.serviceName,
    );
  }

  static String _normalizeHost(String value) {
    var host = value.trim();
    // Zone IDs in IPv6 (fe80::1%en0) are unreliable in Dart WebSocket URIs.
    final zoneIndex = host.indexOf('%');
    if (zoneIndex > 0) {
      host = host.substring(0, zoneIndex);
    }
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  static bool _isIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final n = int.tryParse(part);
      return n != null && n >= 0 && n <= 255;
    });
  }

  static bool _isIpv6(String value) => value.contains(':');

  static bool _isLinkLocalIpv6(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('fe80:');
  }

  @override
  String toString() =>
      'WifiEndpoint(host: $host, port: $port, addresses: $addresses)';
}
