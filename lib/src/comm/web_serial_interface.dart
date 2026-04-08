import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

// ── JS Interop bindings for Web Serial API ──────────────────────────────────
//
// These extension types provide Dart-typed access to the browser's Web Serial
// API. They use `dart:js_interop` extension types (Dart 3.3+) to bind to
// the JavaScript objects without runtime overhead.
//
// Web Serial API reference: https://developer.mozilla.org/en-US/docs/Web/API/Web_Serial_API

/// Access to `navigator.serial`, the entry point for the Web Serial API.
@JS('navigator.serial')
external JSSerial? get _navigatorSerial;

/// The [Serial](https://developer.mozilla.org/en-US/docs/Web/API/Serial)
/// interface. Used to request a port from the user via a browser picker dialog.
extension type JSSerial(JSObject _) implements JSObject {
  /// Prompts the user to select a serial port.
  /// Returns a [JSSerialPort] chosen by the user.
  @JS('requestPort')
  external JSPromise<JSSerialPort> requestPort([JSObject? options]);
}

/// A [SerialPort](https://developer.mozilla.org/en-US/docs/Web/API/SerialPort)
/// from the Web Serial API. Represents an opened serial device.
extension type JSSerialPort(JSObject _) implements JSObject {
  /// Opens the serial port with the given [options] (baud rate, data bits, etc.).
  @JS('open')
  external JSPromise<JSAny?> open(JSObject options);

  /// Closes the serial port and releases the underlying system resource.
  @JS('close')
  external JSPromise<JSAny?> close();

  /// The readable stream for receiving data from the serial port.
  /// Returns `null` if the port is not open or has been closed.
  external JSReadableStream? get readable;

  /// The writable stream for sending data to the serial port.
  /// Returns `null` if the port is not open or has been closed.
  external JSWritableStream? get writable;
}

/// A [ReadableStream](https://developer.mozilla.org/en-US/docs/Web/API/ReadableStream)
/// from the Streams API. Used to read incoming serial data.
extension type JSReadableStream(JSObject _) implements JSObject {
  /// Acquires a reader lock on the stream for reading data.
  external JSReadableStreamReader getReader();
}

/// A [ReadableStreamDefaultReader](https://developer.mozilla.org/en-US/docs/Web/API/ReadableStreamDefaultReader).
/// Reads chunks of data from a [JSReadableStream].
extension type JSReadableStreamReader(JSObject _) implements JSObject {
  /// Reads the next chunk of data. Returns a [JSReadResult] with `done`
  /// and `value` properties.
  external JSPromise<JSReadResult> read();

  /// Releases the reader lock, allowing another reader to acquire it.
  external void releaseLock();

  /// Cancels the stream, signaling that the consumer is no longer interested.
  external JSPromise<JSAny?> cancel();
}

/// The result object from [JSReadableStreamReader.read].
///
/// - [done] is `true` when the stream has been closed.
/// - [value] contains the received bytes as a `Uint8Array`, or `null` if done.
extension type JSReadResult(JSObject _) implements JSObject {
  /// Whether the stream has ended (no more data will arrive).
  external bool get done;

  /// The received byte data, or `null` if [done] is `true`.
  external JSUint8Array? get value;
}

/// A [WritableStream](https://developer.mozilla.org/en-US/docs/Web/API/WritableStream)
/// from the Streams API. Used to send data to the serial port.
extension type JSWritableStream(JSObject _) implements JSObject {
  /// Acquires a writer lock on the stream for sending data.
  external JSWritableStreamWriter getWriter();
}

/// A [WritableStreamDefaultWriter](https://developer.mozilla.org/en-US/docs/Web/API/WritableStreamDefaultWriter).
/// Writes chunks of data to a [JSWritableStream].
extension type JSWritableStreamWriter(JSObject _) implements JSObject {
  /// Writes [data] bytes to the serial port.
  external JSPromise<JSAny?> write(JSUint8Array data);

  /// Releases the writer lock, allowing another writer to acquire it.
  external void releaseLock();

  /// Closes the writable stream.
  external JSPromise<JSAny?> close();
}

// ── Helper to build JS options object ───────────────────────────────────────

/// Converts [WebSerialSettings] into a JavaScript options object
/// suitable for passing to [JSSerialPort.open].
JSObject _buildOpenOptions(WebSerialSettings settings) {
  return {
    'baudRate': settings.baudrate.toJS,
    'dataBits': settings.dataBits.toJS,
    'stopBits': settings.stopBits.toJS,
    'parity': settings.parity.toJS,
    'bufferSize': settings.bufferSize.toJS,
  }.jsify() as JSObject;
}

// ── WebSerialInterface implementation ───────────────────────────────────────

/// Communication interface using the browser's Web Serial API.
///
/// This allows **Flutter Web** applications to communicate with serial
/// devices (e.g., Metratec RFID readers connected via USB) directly
/// from the browser. Requires Chrome or Edge with Web Serial API support.
///
/// When [connect] is called, the browser shows a port picker dialog for
/// the user to select a serial device. Once selected, the port is opened
/// with the configured [WebSerialSettings] and a background read loop
/// pushes incoming data to [rxStream].
///
/// Unlike native [CommInterface] implementations, this uses a **broadcast**
/// [StreamController] for [rxStream] to support multiple listeners in
/// browser environments.
///
/// Example:
/// ```dart
/// if (WebSerialInterface.isSupported) {
///   final comm = WebSerialInterface(WebSerialSettings(baudrate: 115200));
///   await comm.connect();
///   comm.rxStream.listen((data) => print(data));
///   comm.write(Uint8List.fromList('ATI\r'.codeUnits));
///   await comm.disconnect();
/// }
/// ```
class WebSerialInterface implements CommInterface {
  /// The Web Serial settings for this connection.
  final WebSerialSettings _settings;
  final Logger _logger = Logger();

  /// The browser serial port handle, or `null` if not connected.
  JSSerialPort? _port;

  /// The current readable stream reader, or `null` if not reading.
  JSReadableStreamReader? _reader;

  /// The current writable stream writer, or `null` if not writing.
  JSWritableStreamWriter? _writer;

  /// Whether the port is currently connected and open.
  bool _connected = false;

  /// Whether the background read loop is currently active.
  bool _reading = false;

  /// User-provided handler for asynchronous errors.
  void Function(Object, StackTrace)? _onSocketException;

  /// Broadcast stream controller for received data.
  /// Uses broadcast mode to support multiple listeners in browser apps.
  final StreamController<Uint8List> _rxController =
      StreamController<Uint8List>.broadcast();

  /// Creates a Web Serial interface with the given [_settings].
  WebSerialInterface(this._settings);

  /// Returns `true` if the browser supports the Web Serial API.
  ///
  /// This checks for the presence of `navigator.serial`. Returns `false`
  /// in browsers that don't support Web Serial (e.g., Firefox, Safari).
  static bool get isSupported => _navigatorSerial != null;

  @override
  Stream<Uint8List> get rxStream => _rxController.stream;

  @override
  set onSocketException(void Function(Object, StackTrace) onSocketException) {
    _onSocketException = onSocketException;
  }

  @override
  Future<bool> connect({void Function(Object?, StackTrace)? onError}) async {
    if (_connected) {
      _logger.w('WebSerial: Already connected');
      return true;
    }

    try {
      // Check if the browser supports the Web Serial API.
      if (!isSupported) {
        final error = Exception(
            'Web Serial API is not supported in this browser. '
            'Please use Chrome or Edge.');
        _logger.e('WebSerial: API not supported', error: error);
        onError?.call(error, StackTrace.current);
        return false;
      }

      // Request a serial port from the user via the browser's picker dialog.
      // This requires a user gesture (e.g., button click) to trigger.
      _logger.i('WebSerial: Requesting port from user...');
      try {
        _port = await _navigatorSerial!.requestPort().toDart;
      } catch (e, stack) {
        _logger.e(
            'WebSerial: User cancelled port selection or no port available',
            error: e);
        onError?.call(e, stack);
        return false;
      }

      // Open the port with configured baud rate, data bits, etc.
      _logger.i(
          'WebSerial: Opening port with baudrate ${_settings.baudrate}...');
      try {
        await _port!.open(_buildOpenOptions(_settings)).toDart;
      } catch (e, stack) {
        _logger.e('WebSerial: Failed to open port', error: e);
        onError?.call(e, stack);
        _port = null;
        return false;
      }

      _connected = true;

      // Start the background read loop to pipe incoming data to rxStream.
      _startReading();

      _logger.i('WebSerial: Connected successfully');
      return true;
    } catch (e, stack) {
      _logger.e('WebSerial: Unexpected error during connect',
          error: e, stackTrace: stack);
      onError?.call(e, stack);
      _onSocketException?.call(e, stack);
      return false;
    }
  }

  /// Continuously reads data from the serial port's readable stream
  /// and pushes each chunk of bytes to [rxStream].
  ///
  /// This runs as an async fire-and-forget closure. It acquires a reader
  /// lock on each iteration and reads until the stream signals done or
  /// the connection is closed. On read errors, the [_onSocketException]
  /// handler is invoked if available.
  void _startReading() {
    if (_reading) return;
    _reading = true;

    () async {
      try {
        while (_connected && _port?.readable != null) {
          _reader = _port!.readable!.getReader();
          try {
            while (_connected) {
              final result = await _reader!.read().toDart;
              if (result.done) {
                _logger.i('WebSerial: Read stream done');
                break;
              }
              if (result.value != null) {
                final data = result.value!.toDart;
                if (data.isNotEmpty) {
                  _rxController.add(data);
                }
              }
            }
          } catch (e, stack) {
            if (_connected) {
              _logger.e('WebSerial: Read error',
                  error: e, stackTrace: stack);
              _onSocketException?.call(e, stack);
            }
          } finally {
            try {
              _reader?.releaseLock();
            } catch (_) {}
            _reader = null;
          }
        }
      } catch (e, stack) {
        _logger.e('WebSerial: Fatal read loop error',
            error: e, stackTrace: stack);
        _onSocketException?.call(e, stack);
      } finally {
        _reading = false;
      }
    }();
  }

  @override
  Future<void> disconnect() async {
    if (!_connected) return;

    _connected = false;
    _reading = false;

    try {
      // Release the reader lock and cancel any pending reads.
      try {
        await _reader?.cancel().toDart;
      } catch (_) {}
      try {
        _reader?.releaseLock();
      } catch (_) {}
      _reader = null;

      // Release the writer lock.
      try {
        _writer?.releaseLock();
      } catch (_) {}
      _writer = null;

      // Close the serial port.
      try {
        await _port?.close().toDart;
      } catch (e) {
        _logger.w('WebSerial: Error closing port: $e');
      }
      _port = null;

      _logger.i('WebSerial: Disconnected');
    } catch (e, stack) {
      _logger.e('WebSerial: Error during disconnect',
          error: e, stackTrace: stack);
    }
  }

  @override
  Future<void> flush() async {
    // The Web Serial API does not expose a direct flush method.
    // Any buffered data is managed internally by the browser.
  }

  @override
  bool isConnected() => _connected;

  @override
  void setWriteTimeout(int writeTimeout) {
    // The Web Serial API manages write timeouts internally.
  }

  @override
  bool write(Uint8List bytes) {
    if (!_connected || _port?.writable == null) {
      _logger.w('WebSerial: Cannot write - not connected');
      return false;
    }

    try {
      // Acquire a writer lock, write the data, then release the lock.
      // The write is performed asynchronously; we return `true` immediately
      // if the writer was acquired successfully.
      _writer = _port!.writable!.getWriter();
      _writer!.write(bytes.toJS).toDart.then((_) {
        try {
          _writer?.releaseLock();
        } catch (_) {}
      }).catchError((e) {
        _logger.e('WebSerial: Write error', error: e);
        try {
          _writer?.releaseLock();
        } catch (_) {}
      });
      return true;
    } catch (e, stack) {
      _logger.e('WebSerial: Write failed', error: e, stackTrace: stack);
      try {
        _writer?.releaseLock();
      } catch (_) {}
      return false;
    }
  }
}
