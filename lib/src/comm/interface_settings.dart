/// Base class for all interface settings.
abstract class InterfaceSettings {}

/// Settings for Web Serial connections (browser only).
class WebSerialSettings extends InterfaceSettings {
  int baudrate;
  int dataBits;
  int stopBits;
  String parity;
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
class SerialSettings extends InterfaceSettings {
  String serialName;
  int baudrate;
  bool flowControl;
  int stopBits;
  int parity;
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
class TcpSettings extends InterfaceSettings {
  String ipAddr;
  int ipPort;

  TcpSettings(this.ipAddr, this.ipPort);
}

/// Settings for USB serial connections (Android).
class UsbSettings extends InterfaceSettings {
  int deviceId;
  int baudrate;
  bool flowControl;
  int stopBits;
  int parity;
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
