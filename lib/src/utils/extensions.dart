import 'dart:typed_data';

/// Extension methods on [Uint8List] for common byte-level conversions.
extension Uint8ListExtension on Uint8List {
  /// Decodes this byte list as an ASCII string.
  ///
  /// Each byte is treated as an ASCII character code. Non-ASCII bytes
  /// (>127) will produce unexpected characters.
  String toAsciiString() {
    return String.fromCharCodes(this);
  }

  /// Converts this byte list to an uppercase hex string.
  ///
  /// Each byte is represented as two hex digits (e.g., `[0xDE, 0xAD]`
  /// becomes `"DEAD"`).
  String toHexString() {
    return map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join('');
  }
}

/// Extension methods on [String] for hex string conversions.
extension StringExtension on String {
  /// Converts a hex string to a [Uint8List] of bytes.
  ///
  /// The string must contain an even number of hex characters
  /// (e.g., `"DEADBEEF"` becomes `[0xDE, 0xAD, 0xBE, 0xEF]`).
  ///
  /// Throws [FormatException] if the string contains non-hex characters.
  Uint8List hexStringToBytes() {
    List<int> data = [];
    for (int i = 0; i < length ~/ 2; i++) {
      data.add(int.parse(substring(2 * i, 2 * (i + 1)), radix: 16));
    }
    return Uint8List.fromList(data);
  }
}

/// Extension methods on [bool] for AT protocol conversions.
extension BoolExtension on bool {
  /// Converts a boolean to its AT protocol string representation.
  ///
  /// Returns `"1"` for `true`, `"0"` for `false`. Used when building
  /// AT command parameter strings (e.g., inventory settings).
  String toProtocolString() => this ? "1" : "0";
}
