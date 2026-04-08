/// Native platform communication interface exports.
///
/// This file is conditionally imported on native platforms (where
/// `dart.library.io` is available). It provides access to:
/// - [SerialInterface] -- desktop serial ports (Linux, macOS, Windows)
/// - [TcpInterface] -- TCP socket connections (all native platforms)
/// - [UsbInterface] -- Android USB-OTG serial communication
export '../comm/serial_interface.dart' show SerialInterface;
export '../comm/tcp_interface.dart' show TcpInterface;
export '../comm/usb_interface.dart' show UsbInterface;
