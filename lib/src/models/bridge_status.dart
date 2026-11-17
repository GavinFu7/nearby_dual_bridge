import 'bridge_connection_state.dart';
import 'bridge_role.dart';
import 'transport_type.dart';

/// Snapshot of bridge lifecycle for [DualBridgeManager.addStatusListener].
class BridgeStatus {
  const BridgeStatus({
    required this.role,
    required this.connectionState,
    this.activeTransport,
    this.peerCount = 0,
    this.reason,
  });

  final BridgeRole role;
  final BridgeConnectionState connectionState;

  /// Active Client transport, if connected.
  final TransportType? activeTransport;

  /// Connected peers (Host sockets / BLE centrals, or 1 when Client is linked).
  final int peerCount;

  /// Optional machine-readable cause, e.g. `peer_disconnected`, `host_stopped`.
  final String? reason;

  bool get isConnected =>
      connectionState == BridgeConnectionState.connected || peerCount > 0;

  BridgeStatus copyWith({
    BridgeRole? role,
    BridgeConnectionState? connectionState,
    TransportType? activeTransport,
    int? peerCount,
    String? reason,
    bool clearTransport = false,
    bool clearReason = false,
  }) {
    return BridgeStatus(
      role: role ?? this.role,
      connectionState: connectionState ?? this.connectionState,
      activeTransport:
          clearTransport ? null : (activeTransport ?? this.activeTransport),
      peerCount: peerCount ?? this.peerCount,
      reason: clearReason ? null : (reason ?? this.reason),
    );
  }

  @override
  String toString() =>
      'BridgeStatus(role: $role, connection: $connectionState, '
      'transport: $activeTransport, peers: $peerCount, reason: $reason)';
}
