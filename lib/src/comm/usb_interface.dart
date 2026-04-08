import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';
import 'package:logger/logger.dart';
import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

/// USB serial interface for Android devices.
/// Uses the usb_serial package for Android USB-OTG communication.
class UsbInterface implements CommInterface {
  late UsbPort _serialPort;
  final UsbSettings usbSettings;

  StreamController<Uint8List> _rxStreamController = StreamController();

  UsbInterface(this.usbSettings);

  // ignore: unused_field
  int _writeTimeout = 1000;
  bool _isConnected = false;

  var logger = Logger();

  @override
  Stream<Uint8List> get rxStream => _rxStreamController.stream;

  @override
  set onSocketException(void Function(Object, StackTrace) onSocketException) {
    // No socket for USB serial.
  }

  @override
  Future<bool> connect({void Function(Object?, StackTrace)? onError}) async {
    logger.i("Connecting USB");
    if (isConnected()) return true;

    try {
      _serialPort =
          (await UsbSerial.createFromDeviceId(usbSettings.deviceId))!;
      if (await (_serialPort.open()) != true) {
        logger.e("Failed to open USB port");
        return false;
      }
      await _serialPort.setDTR(true);
      await _serialPort.setRTS(true);

      await _serialPort.setPortParameters(
        usbSettings.baudrate,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      _isConnected = true;

      _rxStreamController = StreamController();
      _serialPort.inputStream!.listen((Uint8List event) {
        _rxStreamController.add(event);
      });
    } catch (error, stack) {
      logger.e("Cannot open USB serial:", error: error, stackTrace: stack);
      onError?.call(error, stack);
      return false;
    }

    return true;
  }

  @override
  Future<void> disconnect() async {
    try {
      await _serialPort.close();
      _isConnected = false;
    } catch (e) {
      logger.e("Cannot close USB serial: $e");
    }
  }

  @override
  Future<void> flush() async {
    // Nothing to do for USB serial.
  }

  @override
  bool isConnected() => _isConnected;

  @override
  bool write(Uint8List bytes) {
    if (!isConnected()) return false;
    try {
      _serialPort.write(bytes);
      return true;
    } catch (e) {
      logger.e("Cannot write to USB serial: $e");
      return false;
    }
  }

  @override
  void setWriteTimeout(int writeTimeout) {
    _writeTimeout = writeTimeout;
  }
}
