import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:logger/logger.dart';
import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

/// Native serial port communication interface using `flutter_libserialport`.
///
/// This implementation works on **Linux, macOS, and Windows** desktop
/// platforms. It opens a system serial port (e.g., `/dev/ttyUSB0` or `COM3`)
/// and provides bidirectional byte-level communication with the RFID reader.
///
/// The port is configured with baud rate, data bits, stop bits, parity,
/// and optional hardware flow control from the provided [SerialSettings].
///
/// Example:
/// ```dart
/// final comm = SerialInterface(SerialSettings('/dev/ttyUSB0'));
/// await comm.connect();
/// comm.write(Uint8List.fromList('ATI\r'.codeUnits));
/// comm.rxStream.listen((data) => print(data));
/// await comm.disconnect();
/// ```
class SerialInterface implements CommInterface {
  /// Creates a serial interface for the port specified in [serialSettings].
  ///
  /// The [SerialPort] and [SerialPortReader] are initialized immediately
  /// but the port is not opened until [connect] is called.
  SerialInterface(this.serialSettings) {
    _serialPort = SerialPort(serialSettings.serialName);
    _serialPortReader = SerialPortReader(_serialPort);
  }

  /// The underlying `flutter_libserialport` port handle.
  late SerialPort _serialPort;

  /// Reader that provides the [rxStream] of incoming bytes.
  late SerialPortReader _serialPortReader;

  /// Configuration for this serial connection.
  final SerialSettings serialSettings;

  /// Write timeout in milliseconds. Passed to [SerialPort.write].
  int _writeTimeout = 0;

  @override
  Stream<Uint8List> get rxStream => _serialPortReader.stream;

  @override
  set onSocketException(void Function(Object, StackTrace) onSocketException) {
    // Serial ports don't have an async socket error mechanism.
    // Errors are reported synchronously through write/read failures.
  }

  var logger = Logger();

  @override
  Future<bool> connect({void Function(Object?, StackTrace)? onError}) async {
    if (isConnected()) {
      return true;
    }
    try {
      // Re-create port and reader in case a previous connection was closed.
      _serialPort = SerialPort(serialSettings.serialName);
      _serialPortReader = SerialPortReader(_serialPort);

      if (!_serialPort.openReadWrite()) {
        logger.e(SerialPort.lastError);
        onError?.call(SerialPort.lastError, StackTrace.current);
        _serialPort.dispose();
        return false;
      }
    } catch (e, stack) {
      logger.e(SerialPort.lastError);
      onError?.call(e, stack);
      _serialPort.dispose();
      return false;
    }

    // Apply serial port configuration from settings.
    SerialPortConfig cfg = SerialPortConfig()
      ..setFlowControl(SerialPortFlowControl.dtrDsr);
    if (serialSettings.flowControl) {
      cfg.setFlowControl(1);
    } else {
      cfg.setFlowControl(0);
    }
    cfg.stopBits = serialSettings.stopBits;
    cfg.parity = serialSettings.parity;
    cfg.bits = serialSettings.bits;
    cfg.baudRate = serialSettings.baudrate;
    _serialPort.config = cfg;

    // Flush any stale data in the port buffer after opening.
    _serialPort.flush();

    return true;
  }

  @override
  Future<void> disconnect() async {
    try {
      _serialPortReader.close();
      _serialPort.close();
      _serialPort.dispose();
    } catch (e) {
      logger.e("Cannot close Serial Port: $e");
    }

    // Windows requires a longer delay after closing the port before
    // it can be re-opened. Other platforms need a shorter cooldown.
    if (Platform.isWindows) {
      await Future.delayed(const Duration(milliseconds: 1000));
    } else {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  Future<void> flush() async {
    try {
      _serialPort.flush();
    } catch (e) {
      logger.e("Cannot flush Serial Port: $e");
    }
  }

  @override
  bool isConnected() {
    bool isCon = false;
    try {
      isCon = _serialPort.isOpen;
    } catch (e) {
      // Port may have been disposed; treat as not connected.
    }
    return isCon;
  }

  /// Changes the baud rate on an already-open serial connection.
  ///
  /// Returns `true` if the baud rate was changed successfully, `false`
  /// if the port is not connected or the change failed.
  ///
  /// This is an extra method not part of the [CommInterface] contract,
  /// useful for readers that require a baud rate change after initial
  /// connection (e.g., during firmware update or high-speed mode).
  bool setBaud(int baud) {
    if (!isConnected()) return false;
    try {
      SerialPortConfig cfg = _serialPort.config;
      cfg.baudRate = baud;
      _serialPort.config = cfg;
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  bool write(Uint8List bytes) {
    if (!isConnected()) return false;
    try {
      int byteno = _serialPort.write(bytes, timeout: _writeTimeout);
      return byteno > 0;
    } on SerialPortError catch (e) {
      logger.e("Cannot write to Serial Port: $e (${SerialPort.lastError})");
      return false;
    }
  }

  @override
  void setWriteTimeout(int writeTimeout) {
    _writeTimeout = writeTimeout;
  }
}
