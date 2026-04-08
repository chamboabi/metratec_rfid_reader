/// Base exception class for all RFID reader errors.
///
/// All reader-related exceptions extend this class, allowing callers
/// to catch [ReaderException] as a catch-all, or catch specific
/// subclasses for finer-grained error handling.
///
/// Example:
/// ```dart
/// try {
///   await reader.inventory();
/// } on ReaderTimeoutException {
///   print('No response from reader');
/// } on ReaderNoTagsException {
///   print('No tags in range');
/// } on ReaderException catch (e) {
///   print('Reader error: ${e.cause}');
/// }
/// ```
class ReaderException implements Exception {
  /// Human-readable description of the error.
  String cause;

  /// Optional inner exception or error that triggered this exception.
  Object? inner;

  /// Creates a reader exception with the given [cause] message
  /// and optional [inner] wrapped exception.
  ReaderException(this.cause, {this.inner});

  @override
  String toString() => cause;
}

/// Thrown when a communication error occurs (connection lost, write failed).
///
/// This typically indicates that the physical connection to the reader
/// has been interrupted and a reconnection may be needed.
class ReaderCommException extends ReaderException {
  ReaderCommException(super.cause, {super.inner});
}

/// Thrown when a command times out waiting for a response from the reader.
///
/// This can indicate that the reader is not powered on, not connected,
/// or is busy processing another operation. The timeout duration is
/// specified per-command in [UhfReaderAt] methods.
class ReaderTimeoutException extends ReaderException {
  ReaderTimeoutException(super.cause, {super.inner});
}

/// Thrown when an inventory or tag operation finds no tags in range.
///
/// This is a normal operational condition (not a hardware error) that
/// occurs when no UHF tags are within the reader's field. Callers
/// should handle this gracefully in their UI.
class ReaderNoTagsException extends ReaderException {
  ReaderNoTagsException(super.cause, {super.inner});
}

/// Thrown when a parameter value is outside the valid range.
///
/// Wraps a [RangeError] with additional context about which reader
/// parameter was out of range (e.g., power level, Q value).
class ReaderRangeException extends ReaderException {
  ReaderRangeException(super.cause, {required RangeError inner})
      : super(inner: inner);
}
