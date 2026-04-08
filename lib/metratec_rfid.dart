/// Metratec RFID reader library.
///
/// A cross-platform library for communicating with Metratec UHF RFID readers
/// using the AT command protocol.
///
/// ## Usage
///
/// Import this file for the platform-independent API:
/// ```dart
/// import 'package:metratec_rfid_reader/metratec_rfid.dart';
/// ```
///
/// For platform-specific communication interfaces, also import:
/// ```dart
/// import 'package:metratec_rfid_reader/metratec_rfid_platform.dart';
/// ```
///
/// This conditionally exports [WebSerialInterface] on web, and
/// [SerialInterface], [TcpInterface], [UsbInterface] on native platforms.
library metratec_rfid;

// ── Communication (platform-independent) ────────────────────────────────────
export 'src/comm/comm_interface.dart' show CommInterface;
export 'src/comm/interface_settings.dart'
    show InterfaceSettings, WebSerialSettings, SerialSettings, TcpSettings, UsbSettings;

// ── Parser ──────────────────────────────────────────────────────────────────
export 'src/parser/parser.dart' show Parser, CmdExitCode, ParserResponse;
export 'src/parser/parser_at.dart' show ParserAt;

// ── Reader ──────────────────────────────────────────────────────────────────
export 'src/reader/reader_exception.dart';
export 'src/reader/reader_uhf_at.dart'
    show UhfReaderAt, UhfInvSettings, UhfRwResult, UhfMemoryBank, UhfReaderRegion;

// ── Models ──────────────────────────────────────────────────────────────────
export 'src/models/inventory_result.dart' show InventoryResult;
export 'src/models/uhf_inventory_result.dart' show UhfTag, UhfInventoryResult;
export 'src/models/membank.dart' show Membank;

// ── Utils ───────────────────────────────────────────────────────────────────
export 'src/utils/extensions.dart';
export 'src/utils/heartbeat.dart' show Heartbeat;
