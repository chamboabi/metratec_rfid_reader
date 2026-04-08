import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

// ── JS Interop bindings for Web Serial API (extension types) ────────────────

@JS('navigator.serial')
external JSSerial? get _navigatorSerial;

/// The Serial interface from the Web Serial API.
extension type JSSerial(JSObject _) implements JSObject {
  @JS('requestPort')
  external JSPromise<JSSerialPort> requestPort([JSObject? options]);
}

/// A SerialPort from the Web Serial API.
extension type JSSerialPort(JSObject _) implements JSObject {
  @JS('open')
  external JSPromise<JSAny?> open(JSObject options);

  @JS('close')
  external JSPromise<JSAny?> close();

  external JSReadableStream? get readable;
  external JSWritableStream? get writable;
}

/// A ReadableStream from the Streams API.
extension type JSReadableStream(JSObject _) implements JSObject {
  external JSReadableStreamReader getReader();
}

/// A ReadableStreamDefaultReader from the Streams API.
extension type JSReadableStreamReader(JSObject _) implements JSObject {
  external JSPromise<JSReadResult> read();
  external void releaseLock();
  external JSPromise<JSAny?> cancel();
}

/// The result object from ReadableStreamDefaultReader.read().
extension type JSReadResult(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

/// A WritableStream from the Streams API.
extension type JSWritableStream(JSObject _) implements JSObject {
  external JSWritableStreamWriter getWriter();
}

/// A WritableStreamDefaultWriter from the Streams API.
extension type JSWritableStreamWriter(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSUint8Array data);
  external void releaseLock();
  external JSPromise<JSAny?> close();
}

// ── Helper to build JS options object ───────────────────────────────────────

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

/// Implements [CommInterface] using the browser Web Serial API.
/// This allows Flutter Web apps to communicate with serial devices
/// (e.g., Metratec RFID readers connected via USB).
class WebSerialInterface implements CommInterface {
  final WebSerialSettings _settings;
  final Logger _logger = Logger();

  JSSerialPort? _port;
  JSReadableStreamReader? _reader;
  JSWritableStreamWriter? _writer;
  bool _connected = false;
  bool _reading = false;

  void Function(Object, StackTrace)? _onSocketException;

  final StreamController<Uint8List> _rxController =
      StreamController<Uint8List>.broadcast();

  WebSerialInterface(this._settings);

  /// Check if the browser supports the Web Serial API.
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
      // Check browser support
      if (!isSupported) {
        final error = Exception(
            'Web Serial API is not supported in this browser. '
            'Please use Chrome or Edge.');
        _logger.e('WebSerial: API not supported', error: error);
        onError?.call(error, StackTrace.current);
        return false;
      }

      // Request port from user (browser will show a picker dialog)
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

      // Open the port with the configured settings
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

      // Start reading data from the port
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

  /// Continuously reads data from the serial port and pushes it to [rxStream].
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
      // Release reader lock
      try {
        await _reader?.cancel().toDart;
      } catch (_) {}
      try {
        _reader?.releaseLock();
      } catch (_) {}
      _reader = null;

      // Release writer lock
      try {
        _writer?.releaseLock();
      } catch (_) {}
      _writer = null;

      // Close port
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
    // Web Serial API doesn't have a direct flush method.
  }

  @override
  bool isConnected() => _connected;

  @override
  void setWriteTimeout(int writeTimeout) {
    // Web Serial API manages timeouts internally.
  }

  @override
  bool write(Uint8List bytes) {
    if (!_connected || _port?.writable == null) {
      _logger.w('WebSerial: Cannot write - not connected');
      return false;
    }

    try {
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
