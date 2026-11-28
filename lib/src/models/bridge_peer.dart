import 'transport_type.dart';

/// Host-side peer lifecycle for an incoming Wi-Fi or BLE link.
enum BridgePeerState {
  /// Waiting for Host [DualBridgeManager.approvePeer] / [rejectPeer].
  pending,

  /// Host approved; may exchange messages.
  connected,
}

/// A remote Client visible to the Host (pending approval or connected).
class BridgePeer {
  const BridgePeer({
    required this.id,
    required this.transport,
    required this.state,
    this.label,
    this.remoteAddress,
    required this.connectedAt,
  });

  /// Stable id for approve / reject / disconnect (`wifi:…` or `ble:…`).
  final String id;

  final TransportType transport;
  final BridgePeerState state;

  /// Short display label (IP, BLE UUID fragment, etc.).
  final String? label;

  /// Remote address when known (socket IP or BLE central UUID).
  final String? remoteAddress;

  final DateTime connectedAt;

  bool get isPending => state == BridgePeerState.pending;
  bool get isConnected => state == BridgePeerState.connected;

  BridgePeer copyWith({
    BridgePeerState? state,
    String? label,
    String? remoteAddress,
  }) {
    return BridgePeer(
      id: id,
      transport: transport,
      state: state ?? this.state,
      label: label ?? this.label,
      remoteAddress: remoteAddress ?? this.remoteAddress,
      connectedAt: connectedAt,
    );
  }

  @override
  String toString() =>
      'BridgePeer($id ${transport.name} ${state.name} label=$label)';
}
