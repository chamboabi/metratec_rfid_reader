/// Stub file used as a fallback when neither web nor native platform
/// libraries are detected.
///
/// This should never be reached in practice, since Flutter apps always
/// target either a native platform (where `dart.library.io` is available)
/// or the web (where `dart.library.js_interop` is available). The stub
/// exists to satisfy the conditional export in `metratec_rfid_platform.dart`.
