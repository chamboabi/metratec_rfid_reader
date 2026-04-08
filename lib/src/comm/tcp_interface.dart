import 'dart:async';
import 'dart:io' show Socket;
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

/// TCP socket interface for network-connected RFID readers.
/// Works on all native platforms (Linux, macOS, Windows, Android, iOS).
class TcpInterface implements CommInterface {
  Socket? _tcpSocket;
  StreamController<Uint8List> _rxStreamController = StreamController();
  void Function(Object, StackTrace)? _onSocketException;

  TcpSettings tcpSettings;
  TcpInterface(this.tcpSettings);

  // ignore: unused_field
  int _writeTimeout = 1000;
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

      unawaited(_handleConnectionError(onError: onError));

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
