import 'dart:typed_data';

import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

/// Abstract communication interface for RFID reader communication.
/// Adapted from metratec_device for web compatibility.
abstract class CommInterface {
  CommInterface(InterfaceSettings interfaceSettings);

  /// Get a stream of all received bytes.
  /// Must be a single subscription stream.
  Stream<Uint8List> get rxStream;

  /// Used to set the error handler for errors which may occur
  /// during read or write and can not be caught otherwise.
  set onSocketException(void Function(Object, StackTrace) onSocketException);

  /// Connect to a device.
  /// Returns true on success, false otherwise.
  Future<bool> connect({void Function(Object?, StackTrace)? onError});

  /// Disconnects the connected device.
  Future<void> disconnect();

  /// Flush the device buffer.
  Future<void> flush();

  /// Check if a device is currently connected.
  bool isConnected();

  /// Set the write timeout for the device.
  void setWriteTimeout(int writeTimeout);

  /// Write bytes to the device.
  /// Returns true on success, false otherwise.
  bool write(Uint8List bytes);
}
