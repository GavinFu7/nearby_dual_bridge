import 'dart:convert';

/// Shared JSON encode/decode helpers for Wi-Fi and BLE message planes.
class MessageCodec {
  const MessageCodec();

  String encode(Map<String, dynamic> data) => jsonEncode(data);

  Map<String, dynamic> decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Expected JSON object, got ${decoded.runtimeType}');
    }
    return decoded;
  }

  Map<String, dynamic> decodeBytes(List<int> bytes) =>
      decode(utf8.decode(bytes));

  List<int> encodeBytes(Map<String, dynamic> data) =>
      utf8.encode(encode(data));
}
