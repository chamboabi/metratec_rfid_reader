/// Platform-specific communication interfaces.
///
/// This file conditionally exports the correct communication interface
/// for the current platform:
///
/// - **Web**: [WebSerialInterface] (uses the browser Web Serial API)
/// - **Native**: [SerialInterface] (desktop serial ports),
///   [TcpInterface] (TCP sockets), [UsbInterface] (Android USB-OTG)
///
/// Usage:
/// ```dart
/// import 'package:metratec_rfid_reader/metratec_rfid.dart';
/// import 'package:metratec_rfid_reader/metratec_rfid_platform.dart';
/// ```
library metratec_rfid_platform;

export 'src/platform/platform_stub.dart'
    if (dart.library.io) 'src/platform/platform_native.dart'
    if (dart.library.js_interop) 'src/platform/platform_web.dart';
