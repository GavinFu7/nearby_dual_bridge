import 'bridge_peer.dart';
import 'transport_type.dart';

/// Peer link lifecycle on a single transport (Wi-Fi socket or BLE link).
enum BridgePeerEventType {
  /// Incoming link waiting for Host approval (when approval is required).
  connectionRequest,

  /// Peer is approved / auto-accepted and may exchange messages.
  connected,

  /// Host rejected a pending connection request.
  rejected,

  /// Peer left, was kicked, or the link dropped.
  disconnected,
}

class BridgePeerEvent {
  const BridgePeerEvent({
    required this.transport,
    required this.type,
    required this.peerCount,
    this.peer,
  });

  final TransportType transport;
  final BridgePeerEventType type;

  /// Remaining **approved** peers on this transport after the event.
  final int peerCount;

  /// The peer this event refers to, when known.
  final BridgePeer? peer;

  @override
  String toString() =>
      'BridgePeerEvent($transport $type peers=$peerCount peer=$peer)';
}
