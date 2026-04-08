/// Base exception for reader errors.
class ReaderException implements Exception {
  String cause;
  Object? inner;
  ReaderException(this.cause, {this.inner});

  @override
  String toString() => cause;
}

/// Communication error (connection lost, write failed, etc.).
class ReaderCommException extends ReaderException {
  ReaderCommException(super.cause, {super.inner});
}

/// Command timed out waiting for response.
class ReaderTimeoutException extends ReaderException {
  ReaderTimeoutException(super.cause, {super.inner});
}

/// No tags found during inventory or read/write operation.
class ReaderNoTagsException extends ReaderException {
  ReaderNoTagsException(super.cause, {super.inner});
}

/// Value out of valid range.
class ReaderRangeException extends ReaderException {
  ReaderRangeException(super.cause, {required RangeError inner})
      : super(inner: inner);
}
