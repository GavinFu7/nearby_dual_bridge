import 'transport_type.dart';

/// Peer link up/down on a single transport (Wi-Fi socket or BLE link).
enum BridgePeerEventType {
  connected,
  disconnected,
}

class BridgePeerEvent {
  const BridgePeerEvent({
    required this.transport,
    required this.type,
    required this.peerCount,
  });

  final TransportType transport;
  final BridgePeerEventType type;

  /// Remaining peers on this transport after the event.
  final int peerCount;

  @override
  String toString() =>
      'BridgePeerEvent($transport $type peers=$peerCount)';
}
