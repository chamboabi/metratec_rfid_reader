import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';
import 'package:logger/logger.dart';
import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

/// USB serial communication interface for Android devices.
///
/// This implementation uses the `usb_serial` package to communicate
/// with RFID readers connected via **Android USB-OTG**. The device ID
/// from [UsbSettings] identifies which USB device to open.
///
/// The connection sets DTR and RTS signals, and configures the port
/// with the baud rate and data format from [UsbSettings].
///
/// Example:
/// ```dart
/// final comm = UsbInterface(UsbSettings(deviceId, baudrate: 115200));
/// await comm.connect();
/// comm.write(Uint8List.fromList('ATI\r'.codeUnits));
/// comm.rxStream.listen((data) => print(data));
/// await comm.disconnect();
/// ```
class UsbInterface implements CommInterface {
  /// The underlying USB serial port handle.
  late UsbPort _serialPort;

  /// Configuration for this USB serial connection.
  final UsbSettings usbSettings;

  /// Internal stream controller that relays received data from the
  /// USB port to [rxStream]. A new controller is created on each [connect].
  StreamController<Uint8List> _rxStreamController = StreamController();

  /// Creates a USB serial interface with the given [usbSettings].
  UsbInterface(this.usbSettings);

  // ignore: unused_field
  int _writeTimeout = 1000;

  /// Tracks whether the USB port is currently open, since the
  /// `usb_serial` package does not provide a direct `isOpen` getter.
  bool _isConnected = false;

  var logger = Logger();

  @override
  Stream<Uint8List> get rxStream => _rxStreamController.stream;

  @override
  set onSocketException(void Function(Object, StackTrace) onSocketException) {
    // USB serial does not have an async socket error mechanism.
    // Errors are reported through write/read failures.
  }

  @override
  Future<bool> connect({void Function(Object?, StackTrace)? onError}) async {
    logger.i("Connecting USB");
    if (isConnected()) return true;

    try {
      // Create a UsbPort from the device ID provided in settings.
      _serialPort =
          (await UsbSerial.createFromDeviceId(usbSettings.deviceId))!;
      if (await (_serialPort.open()) != true) {
        logger.e("Failed to open USB port");
        return false;
      }

      // Set DTR and RTS signals, required by most USB-serial adapters.
      await _serialPort.setDTR(true);
      await _serialPort.setRTS(true);

      // Configure port parameters (baud rate, data bits, stop bits, parity).
      await _serialPort.setPortParameters(
        usbSettings.baudrate,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      _isConnected = true;

      // Create a fresh stream controller and pipe incoming USB data through it.
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
    // The usb_serial package does not provide a flush method.
    // Stale data is typically consumed by the read stream.
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
