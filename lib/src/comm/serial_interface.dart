import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:logger/logger.dart';
import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

/// Native serial port interface using flutter_libserialport.
/// Works on Linux, macOS, and Windows.
class SerialInterface implements CommInterface {
  SerialInterface(this.serialSettings) {
    _serialPort = SerialPort(serialSettings.serialName);
    _serialPortReader = SerialPortReader(_serialPort);
  }

  late SerialPort _serialPort;
  late SerialPortReader _serialPortReader;
  final SerialSettings serialSettings;

  int _writeTimeout = 0;

  @override
  Stream<Uint8List> get rxStream => _serialPortReader.stream;

  @override
  set onSocketException(void Function(Object, StackTrace) onSocketException) {
    // No socket object for serial ports.
  }

  var logger = Logger();

  @override
  Future<bool> connect({void Function(Object?, StackTrace)? onError}) async {
    if (isConnected()) {
      return true;
    }
    try {
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
      // stays false
    }
    return isCon;
  }

  /// Change the baud rate on an open connection.
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
