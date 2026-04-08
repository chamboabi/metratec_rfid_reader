import 'dart:typed_data';

extension Uint8ListExtension on Uint8List {
  String toAsciiString() {
    return String.fromCharCodes(this);
  }

  String toHexString() {
    return map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join('');
  }
}

extension StringExtension on String {
  /// Convert a hex string to bytes.
  /// May throw a FormatException if called on a non-hex string.
  Uint8List hexStringToBytes() {
    List<int> data = [];
    for (int i = 0; i < length ~/ 2; i++) {
      data.add(int.parse(substring(2 * i, 2 * (i + 1)), radix: 16));
    }
    return Uint8List.fromList(data);
  }
}

extension BoolExtension on bool {
  String toProtocolString() => this ? "1" : "0";
}
