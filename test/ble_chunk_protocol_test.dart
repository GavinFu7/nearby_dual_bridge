import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge.dart';

void main() {
  group('BleChunkProtocol', () {
    test('round-trips a long JSON payload across chunks', () {
      final protocol = BleChunkProtocol(maxPayloadPerChunk: 32);
      final payload = <String, dynamic>{
        'type': 'chat',
        'text': 'A' * 200,
        'meta': {'n': 42},
      };

      final frames = protocol.encode(payload);
      expect(frames.length, greaterThan(1));

      final reassembler = protocol.createReassembler();
      Map<String, dynamic>? result;
      for (final frame in frames) {
        result = reassembler.add(frame);
      }

      expect(result, equals(payload));
    });

    test('encodes a single-frame small message', () {
      final protocol = BleChunkProtocol(maxPayloadPerChunk: 180);
      final frames = protocol.encode({'ok': true});
      expect(frames, hasLength(1));
      expect(frames.first[0] & BleChunkProtocol.flagLast, isNonZero);

      final decoded = protocol.createReassembler().add(frames.first);
      expect(decoded, equals({'ok': true}));
    });
  });
}
