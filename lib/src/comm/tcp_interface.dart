import 'dart:async';
import 'dart:io' show Socket;
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

/// TCP socket communication interface for network-connected RFID readers.
///
/// This implementation works on **all native platforms** (Linux, macOS,
/// Windows, Android, iOS) via `dart:io` sockets. It connects to an
/// RFID reader over TCP/IP using the IP address and port from the
/// provided [TcpSettings].
///
/// The socket connection is monitored for errors via the [Socket.done]
/// future, and any errors are reported through the [onSocketException]
/// handler or the [onError] callback passed to [connect].
///
/// Example:
/// ```dart
/// final comm = TcpInterface(TcpSettings('192.168.1.100', 10001));
/// await comm.connect();
/// comm.write(Uint8List.fromList('ATI\r'.codeUnits));
/// comm.rxStream.listen((data) => print(data));
/// await comm.disconnect();
/// ```
class TcpInterface implements CommInterface {
  /// The underlying TCP socket, or `null` if not connected.
  Socket? _tcpSocket;

  /// Internal stream controller that relays received data from the
  /// socket to [rxStream]. A new controller is created on each [connect].
  StreamController<Uint8List> _rxStreamController = StreamController();

  /// User-provided handler for asynchronous socket errors.
  void Function(Object, StackTrace)? _onSocketException;

  /// Configuration for this TCP connection.
  TcpSettings tcpSettings;

  /// Creates a TCP interface with the given [tcpSettings].
  TcpInterface(this.tcpSettings);

  // ignore: unused_field
  int _writeTimeout = 1000;

  /// Timeout for the initial TCP connection attempt, in milliseconds.
  final int _connectTimeout = 1000;

  var logger = Logger();

  @override
  Stream<Uint8List> get rxStream => _rxStreamController.stream;

  @override
  set onSocketException(void Function(Object, StackTrace) onSocketException) {
    _onSocketException = onSocketException;
  }

  @override
  Future<bool> connect({void Function(Object?, StackTrace)? onError}) async {
    if (isConnected()) return true;

    try {
      _tcpSocket = await Socket.connect(
        tcpSettings.ipAddr,
        tcpSettings.ipPort,
        timeout: Duration(milliseconds: _connectTimeout),
      );

      // Monitor the socket's done future for connection errors
      // (e.g., remote host closes the connection unexpectedly).
      unawaited(_handleConnectionError(onError: onError));

      // Create a fresh stream controller and pipe socket data through it.
      _rxStreamController = StreamController();
      _tcpSocket!.listen((event) {
        _rxStreamController.add(event);
      });
    } catch (error, stack) {
      logger.e("Cannot open TCP socket:", error: error, stackTrace: stack);
      onError?.call(error, stack);
      return false;
    }
    return true;
  }

  /// Monitors the TCP socket's [done] future and reports errors
  /// through the configured error handlers.
  ///
  /// This runs as an unawaited future so that connection errors
  /// occurring after [connect] returns are still handled properly.
  Future<void> _handleConnectionError(
      {void Function(Object?, StackTrace)? onError}) async {
    try {
      await _tcpSocket!.done.onError(_onSocketException ??
          onError ??
          (error, stack) {
            logger.e(
              "Unhandled TCP socket exception!",
              error: error,
              stackTrace: stack,
            );
          });
    } catch (ex, stack) {
      onError?.call(ex, stack);
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _tcpSocket?.close();
      _tcpSocket = null;
    } catch (e) {
      logger.e("Cannot close TCP socket: $e");
    }
  }

  @override
  Future<void> flush() async {
    try {
      await _tcpSocket?.flush();
    } catch (e) {
      logger.e("Cannot flush TCP socket: $e");
    }
  }

  @override
  bool isConnected() => _tcpSocket != null;

  @override
  bool write(Uint8List bytes) {
    if (!isConnected()) return false;
    try {
      _tcpSocket!.add(bytes);
      return true;
    } catch (e) {
      logger.e("Cannot write to TCP socket: $e");
      return false;
    }
  }

  @override
  void setWriteTimeout(int writeTimeout) {
    _writeTimeout = writeTimeout;
  }
}
