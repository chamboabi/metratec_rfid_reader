import 'dart:typed_data';

import 'package:metratec_rfid_reader/src/comm/interface_settings.dart';

/// Abstract communication interface for RFID reader communication.
///
/// This defines the contract that all transport backends must implement.
/// Each platform has its own concrete implementation:
/// - [WebSerialInterface] for browser-based Web Serial API
/// - [SerialInterface] for native desktop serial ports
/// - [TcpInterface] for TCP socket connections
/// - [UsbInterface] for Android USB-OTG serial
///
/// The interface provides a byte-level transport layer: writing raw bytes
/// to the device and receiving them back via [rxStream]. Higher-level
/// protocol parsing (AT commands, response matching) is handled by the
/// [Parser] layer above.
abstract class CommInterface {
  /// Creates a new communication interface with the given [interfaceSettings].
  ///
  /// Subclasses use the settings to configure transport parameters
  /// (baud rate, IP address, device ID, etc.).
  CommInterface(InterfaceSettings interfaceSettings);

  /// Stream of raw bytes received from the device.
  ///
  /// Implementations must provide a single-subscription stream (except
  /// [WebSerialInterface] which uses a broadcast stream for browser
  /// compatibility). The [Parser] subscribes to this stream and splits
  /// incoming bytes into lines for protocol processing.
  Stream<Uint8List> get rxStream;

  /// Sets an error handler for asynchronous errors that occur during
  /// read or write operations and cannot be caught through normal
  /// try/catch blocks.
  ///
  /// For example, a TCP socket may encounter an error after `connect()`
  /// returns, and this handler will be called in that case. Serial and
  /// USB implementations typically no-op this setter since they don't
  /// have a persistent socket connection to monitor.
  set onSocketException(void Function(Object, StackTrace) onSocketException);

  /// Connects to the RFID reader device.
  ///
  /// Returns `true` if the connection was established successfully,
  /// `false` otherwise. The optional [onError] callback is invoked if
  /// an error occurs during connection or later during the connection
  /// lifetime (for transports that support it).
  ///
  /// If already connected, implementations should return `true` immediately.
  Future<bool> connect({void Function(Object?, StackTrace)? onError});

  /// Disconnects from the device and releases all resources.
  ///
  /// After calling this method, [isConnected] should return `false`.
  /// It is safe to call this method even if already disconnected.
  Future<void> disconnect();

  /// Flushes any buffered data in the device's communication buffer.
  ///
  /// This is useful after connecting to clear any stale data. Not all
  /// transports support flushing (e.g., USB serial is a no-op).
  Future<void> flush();

  /// Returns `true` if the device is currently connected and ready
  /// for communication.
  bool isConnected();

  /// Sets the write timeout in milliseconds.
  ///
  /// This controls how long [write] will wait before giving up.
  /// Not all transports honor this value (e.g., Web Serial manages
  /// timeouts internally).
  void setWriteTimeout(int writeTimeout);

  /// Writes raw bytes to the device.
  ///
  /// Returns `true` if the bytes were sent successfully, `false` if
  /// the write failed (e.g., device not connected, port error).
  /// The [bytes] parameter contains the raw data to send, including
  /// the AT command string and end-of-line characters.
  bool write(Uint8List bytes);
}
