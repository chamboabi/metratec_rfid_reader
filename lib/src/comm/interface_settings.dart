/// Base class for all communication interface settings.
///
/// Each transport backend has its own settings subclass that holds
/// the configuration parameters needed to establish a connection.
/// Pass the appropriate settings object when constructing a
/// [CommInterface] implementation.
abstract class InterfaceSettings {}

/// Settings for Web Serial API connections (browser only).
///
/// Used with [WebSerialInterface] to configure the serial port
/// parameters when connecting via the browser's Web Serial API.
/// These values are passed to the browser's `SerialPort.open()` method.
///
/// Example:
/// ```dart
/// final settings = WebSerialSettings(baudrate: 115200);
/// final comm = WebSerialInterface(settings);
/// ```
class WebSerialSettings extends InterfaceSettings {
  /// Baud rate for the serial connection. Default: 115200.
  int baudrate;

  /// Number of data bits per frame. Default: 8.
  int dataBits;

  /// Number of stop bits. Default: 1.
  int stopBits;

  /// Parity mode: "none", "even", or "odd". Default: "none".
  String parity;

  /// Read buffer size in bytes. Default: 255.
  int bufferSize;

  WebSerialSettings({
    this.baudrate = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = 'none',
    this.bufferSize = 255,
  });
}

/// Settings for native serial port connections (desktop: Linux, macOS, Windows).
///
/// Used with [SerialInterface] to configure a native serial port
/// via `flutter_libserialport`.
///
/// Example:
/// ```dart
/// final settings = SerialSettings('/dev/ttyUSB0', baudrate: 115200);
/// final comm = SerialInterface(settings);
/// ```
class SerialSettings extends InterfaceSettings {
  /// System name of the serial port (e.g., "/dev/ttyUSB0", "COM3").
  String serialName;

  /// Baud rate for the serial connection. Default: 115200.
  int baudrate;

  /// Whether to enable hardware flow control (DTR/DSR). Default: false.
  bool flowControl;

  /// Number of stop bits. Default: 1.
  int stopBits;

  /// Parity setting. Use -1 for none. Default: -1.
  int parity;

  /// Number of data bits per frame. Default: 8.
  int bits;

  SerialSettings(
    this.serialName, {
    this.baudrate = 115200,
    this.bits = 8,
    this.parity = -1,
    this.stopBits = 1,
    this.flowControl = false,
  });
}

/// Settings for TCP socket connections (all native platforms).
///
/// Used with [TcpInterface] for network-connected RFID readers
/// that expose a TCP socket for AT command communication.
///
/// Example:
/// ```dart
/// final settings = TcpSettings('192.168.1.100', 10001);
/// final comm = TcpInterface(settings);
/// ```
class TcpSettings extends InterfaceSettings {
  /// IP address or hostname of the reader.
  String ipAddr;

  /// TCP port number of the reader.
  int ipPort;

  TcpSettings(this.ipAddr, this.ipPort);
}

/// Settings for USB serial connections (Android).
///
/// Used with [UsbInterface] for Android USB-OTG serial communication
/// via the `usb_serial` package.
///
/// Example:
/// ```dart
/// final settings = UsbSettings(deviceId, baudrate: 115200);
/// final comm = UsbInterface(settings);
/// ```
class UsbSettings extends InterfaceSettings {
  /// USB device ID as returned by the `usb_serial` package.
  int deviceId;

  /// Baud rate for the serial connection. Default: 115200.
  int baudrate;

  /// Whether to enable hardware flow control. Default: false.
  bool flowControl;

  /// Number of stop bits. Default: 1.
  int stopBits;

  /// Parity setting. Use -1 for none. Default: -1.
  int parity;

  /// Number of data bits per frame. Default: 8.
  int bits;

  UsbSettings(
    this.deviceId, {
    this.baudrate = 115200,
    this.bits = 8,
    this.parity = -1,
    this.stopBits = 1,
    this.flowControl = false,
  });
}
