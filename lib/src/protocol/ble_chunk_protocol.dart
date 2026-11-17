import 'dart:convert';
import 'dart:typed_data';

/// BLE MTU-safe framing protocol for reassembling long JSON payloads.
///
/// Wire format (binary):
/// ```
/// [flags:1][seq:2][total:2][payload...]
/// ```
/// - `flags` bit0 = last chunk (`0x01`)
/// - `seq` / `total` are big-endian uint16
/// - payload is UTF-8 bytes of the JSON (split across chunks)
///
/// Full send/receive helpers will be wired into [BleTransport] later.
class BleChunkProtocol {
  BleChunkProtocol({this.maxPayloadPerChunk = 180});

  /// Bytes available for payload after the 5-byte header.
  /// Keep conservative vs. typical ATT MTU (23 → ~20 usable; after negotiation often 180–500).
  final int maxPayloadPerChunk;

  static const int headerLength = 5;
  static const int flagLast = 0x01;

  /// Split [data] JSON map into BLE-safe chunks.
  List<Uint8List> encode(Map<String, dynamic> data) {
    final bytes = utf8.encode(jsonEncode(data));
    if (bytes.isEmpty) {
      return [Uint8List.fromList([flagLast, 0, 0, 0, 1])];
    }

    final total = (bytes.length / maxPayloadPerChunk).ceil();
    if (total > 0xFFFF) {
      throw StateError('Payload too large for BleChunkProtocol ($total chunks)');
    }

    final chunks = <Uint8List>[];
    for (var seq = 0; seq < total; seq++) {
      final start = seq * maxPayloadPerChunk;
      final end = (start + maxPayloadPerChunk).clamp(0, bytes.length);
      final slice = bytes.sublist(start, end);
      final isLast = seq == total - 1;

      final frame = Uint8List(headerLength + slice.length);
      frame[0] = isLast ? flagLast : 0x00;
      frame[1] = (seq >> 8) & 0xFF;
      frame[2] = seq & 0xFF;
      frame[3] = (total >> 8) & 0xFF;
      frame[4] = total & 0xFF;
      frame.setRange(headerLength, frame.length, slice);
      chunks.add(frame);
    }
    return chunks;
  }

  /// Incremental reassembler for incoming frames.
  BleChunkReassembler createReassembler() => BleChunkReassembler();
}

/// Collects framed chunks until a complete JSON message is available.
class BleChunkReassembler {
  final Map<int, Uint8List> _parts = {};
  int? _expectedTotal;

  /// Feed one framed chunk. Returns decoded JSON when the message is complete.
  Map<String, dynamic>? add(Uint8List frame) {
    if (frame.length < BleChunkProtocol.headerLength) {
      throw FormatException('BLE frame too short: ${frame.length}');
    }

    final flags = frame[0];
    final seq = (frame[1] << 8) | frame[2];
    final total = (frame[3] << 8) | frame[4];
    final payload = frame.sublist(BleChunkProtocol.headerLength);

    if (total <= 0) {
      throw FormatException('Invalid BLE chunk total: $total');
    }
    if (seq >= total) {
      throw FormatException('Invalid BLE chunk seq: $seq / $total');
    }

    _expectedTotal ??= total;
    if (_expectedTotal != total) {
      _reset();
      _expectedTotal = total;
    }

    _parts[seq] = Uint8List.fromList(payload);

    final isLast = (flags & BleChunkProtocol.flagLast) != 0;
    if (!isLast && _parts.length < total) {
      return null;
    }
    if (_parts.length < total) {
      return null;
    }

    final buffer = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      final part = _parts[i];
      if (part == null) {
        return null;
      }
      buffer.add(part);
    }

    _reset();
    final jsonText = utf8.decode(buffer.takeBytes());
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Expected JSON object, got ${decoded.runtimeType}');
    }
    return decoded;
  }

  void _reset() {
    _parts.clear();
    _expectedTotal = null;
  }

  void reset() => _reset();
}
