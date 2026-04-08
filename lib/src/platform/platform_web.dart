/// Web platform communication interface export.
///
/// This file is conditionally imported on web platforms (where
/// `dart.library.js_interop` is available). It provides access to:
/// - [WebSerialInterface] -- browser-based Web Serial API communication
export '../comm/web_serial_interface.dart' show WebSerialInterface;
