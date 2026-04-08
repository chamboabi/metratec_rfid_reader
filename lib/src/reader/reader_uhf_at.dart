import 'dart:async';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';
import 'package:metratec_rfid_reader/src/models/uhf_inventory_result.dart';
import 'package:metratec_rfid_reader/src/parser/parser.dart';
import 'package:metratec_rfid_reader/src/parser/parser_at.dart';
import 'package:metratec_rfid_reader/src/reader/reader_exception.dart';
import 'package:metratec_rfid_reader/src/utils/extensions.dart';
import 'package:metratec_rfid_reader/src/utils/heartbeat.dart';

/// Configuration for UHF inventory response format.
///
/// Controls which optional fields are included in inventory responses
/// from the reader. These settings correspond to the `AT+INVS` command.
///
/// - [ont] -- include the "on time" field (how long the tag was visible).
/// - [rssi] -- include the received signal strength indicator.
/// - [tid] -- include the tag's TID (unique transponder ID).
/// - [fastStart] -- enable fast-start mode for quicker initial reads.
class UhfInvSettings {
  /// Whether to include the "on time" field in inventory responses.
  bool ont;

  /// Whether to include RSSI (signal strength) in inventory responses.
  bool rssi;

  /// Whether to include TID (transponder ID) in inventory responses.
  bool tid;

  /// Whether to enable fast-start mode.
  bool fastStart;

  /// Creates inventory settings with the specified flags.
  UhfInvSettings(this.ont, this.rssi, this.tid, this.fastStart);

  /// Converts the settings to the AT protocol string format.
  ///
  /// Returns a comma-separated string of "0" and "1" values
  /// suitable for the `AT+INVS=` command (e.g., `"0,1,1,0"`).
  String toProtocolString() =>
      [ont, rssi, tid, fastStart].map((e) => e.toProtocolString()).join(",");

  @override
  String toString() => "ONT=$ont;RSSI=$rssi;TID=$tid;FS=$fastStart";
}

/// Result of a single tag read or write operation.
///
/// Returned by [UhfReaderAt.readTag] and [UhfReaderAt.writeTag].
/// Each result corresponds to one tag that was affected by the operation.
class UhfRwResult {
  /// The EPC (Electronic Product Code) of the tag.
  String epc;

  /// Whether the read/write operation succeeded for this tag.
  bool ok;

  /// The data read from the tag (empty for write operations or failed reads).
  Uint8List data;

  /// Creates a read/write result for a tag with the given [epc],
  /// success status [ok], and [data] payload.
  UhfRwResult(this.epc, this.ok, this.data);

  @override
  String toString() => "EPC=$epc;OK=$ok,DATA=$data";
}

/// Available UHF tag memory banks for the AT protocol.
///
/// Used with [UhfReaderAt.readTag], [UhfReaderAt.writeTag],
/// [UhfReaderAt.lockMembank], and related methods to specify which
/// memory bank to operate on.
enum UhfMemoryBank {
  /// Protocol Control (PC) bits -- contains tag metadata.
  pc,

  /// Electronic Product Code -- the primary tag identifier.
  epc,

  /// Transponder ID -- a factory-programmed unique identifier.
  tid,

  /// User memory -- application-specific data storage.
  usr;

  /// Returns the AT protocol string for this memory bank
  /// (e.g., `"EPC"`, `"TID"`, `"USR"`, `"PC"`).
  String get protocolString => switch (this) {
        UhfMemoryBank.pc => "PC",
        UhfMemoryBank.epc => "EPC",
        UhfMemoryBank.tid => "TID",
        UhfMemoryBank.usr => "USR",
      };
}

/// Regulatory regions supported by the reader.
///
/// UHF RFID operates on different frequency bands depending on the
/// region. The reader must be configured for the correct region to
/// comply with local regulations.
enum UhfReaderRegion {
  /// European Telecommunications Standards Institute (865-868 MHz).
  etsi,

  /// ETSI upper band (915-921 MHz, used in some EU countries).
  etsiHigh,

  /// Federal Communications Commission (902-928 MHz, US/Canada).
  fcc;

  /// Returns the AT protocol string for this region
  /// (e.g., `"ETSI"`, `"ETSI_HIGH"`, `"FCC"`).
  String get protocolString => switch (this) {
        UhfReaderRegion.etsi => "ETSI",
        UhfReaderRegion.etsiHigh => "ETSI_HIGH",
        UhfReaderRegion.fcc => "FCC",
      };
}

/// High-level API for Metratec UHF RFID readers using the AT protocol.
///
/// This is the primary user-facing class in the library. It wraps a
/// [CommInterface] and provides typed methods for all reader operations:
/// inventory scanning, tag read/write, configuration, heartbeat monitoring,
/// and more.
///
/// ## Typical usage
///
/// ```dart
/// // 1. Create a communication interface for your platform.
/// final comm = WebSerialInterface(WebSerialSettings(baudrate: 115200));
///
/// // 2. Create the reader.
/// final reader = UhfReaderAt(comm);
///
/// // 3. Connect.
/// await reader.connect(onError: (e, s) => print('Error: $e'));
///
/// // 4. Use the reader.
/// final tags = await reader.inventory();
/// for (final result in tags) {
///   print('EPC: ${result.tag.epc}');
/// }
///
/// // 5. Disconnect when done.
/// await reader.disconnect();
/// ```
///
/// ## Continuous inventory
///
/// For real-time tag scanning, use [startContinuousInventory] and
/// listen to [cinvStream]:
///
/// ```dart
/// reader.cinvStream.listen((round) {
///   for (final result in round) {
///     print('Tag: ${result.tag.epc}');
///   }
/// });
/// await reader.startContinuousInventory();
/// ```
///
/// ## Error handling
///
/// Most methods throw typed [ReaderException] subclasses:
/// - [ReaderTimeoutException] -- no response from reader
/// - [ReaderNoTagsException] -- no tags found
/// - [ReaderCommException] -- communication failure
class UhfReaderAt {
  /// The underlying communication interface.
  final CommInterface _commInterface;

  /// The AT protocol parser used for command/response handling.
  final ParserAt _parser;

  /// Logger instance for this reader.
  final Logger logger = Logger();

  /// Regex pattern for validating hex strings (used in read/write/mask).
  final RegExp hexRegEx = RegExp(r"^[a-fA-F0-9]+$");

  /// Heartbeat timer for connection aliveness monitoring.
  ///
  /// Use [startHeartBeat] and [stopHeartBeat] to control it.
  /// The heartbeat is fed automatically when `+HBT` unsolicited
  /// responses arrive from the reader.
  final Heartbeat heartbeat = Heartbeat();

  /// Broadcast stream controller for continuous inventory results.
  ///
  /// Each event is a list of [UhfInventoryResult] representing one
  /// "round" of continuous scanning. Use [cinvStream] to listen.
  final StreamController<List<UhfInventoryResult>> cinvStreamCtrl =
      StreamController.broadcast();

  /// Cached inventory settings, updated by [getInventorySettings].
  /// Used internally by inventory parsing to know which fields to expect.
  UhfInvSettings? _invSettings;

  /// Accumulator for tags during continuous inventory.
  /// Tags are collected here until a "ROUND FINISHED" line arrives,
  /// at which point they are emitted as a batch on [cinvStream].
  final List<UhfInventoryResult> _cinv = [];

  // ── Current reader state (cached from get/set operations) ─────────────

  /// The current regulatory region (e.g., "ETSI", "FCC").
  String? currentRegion;

  /// The current output power level(s) in dBm, one per antenna port.
  List<int>? currentPower;

  /// The current Q value (anti-collision parameter).
  int? currentQ;

  /// The minimum Q value in the dynamic Q range.
  int? currentMinQ;

  /// The maximum Q value in the dynamic Q range.
  int? currentMaxQ;

  /// The currently active antenna port number (1-based).
  int invAntenna = 1;

  /// The number of antenna ports detected from the power query.
  int antennaCount = 1;

  /// The current Gen2 session value (e.g., "0", "1", "2", "3").
  String? currentSession;

  /// The current RF modulation mode.
  int? currentRfMode;

  /// The list of antenna ports used for multiplexed inventory.
  List<int> currentMuxAntenna = [1];

  /// Creates a UHF AT reader that communicates over [_commInterface].
  ///
  /// Initializes the [ParserAt] with carriage return (`"\r"`) as the
  /// end-of-line character and registers unsolicited event handlers for:
  /// - `+HBT` -- heartbeat responses (feeds the [heartbeat] timer)
  /// - `+CINV` / `+CMINV` -- continuous inventory tag data
  /// - `+CINVR` -- continuous inventory reports with antenna info
  UhfReaderAt(this._commInterface)
      : _parser = ParserAt(_commInterface, "\r") {
    // Register unsolicited event handlers for async reader events.
    _parser.registerEvent(ParserResponse("+HBT", (_) {
      try {
        heartbeat.feed();
      } catch (e) {
        logger.e('Error in heartbeat handler', error: e);
      }
    }));
    _parser.registerEvent(ParserResponse("+CINV", _handleCinvUrc));
    _parser.registerEvent(ParserResponse("+CMINV", _handleCinvUrc));
    _parser.registerEvent(ParserResponse("+CINVR", _handleCinvReportUrc));
  }

  /// Sets an optional callback for raw data logging.
  ///
  /// When set, every sent AT command and received line is passed to
  /// the callback. The `isOutgoing` parameter is `true` for commands
  /// sent to the reader, `false` for lines received from the reader.
  /// Useful for building debug/terminal views.
  set onRawData(void Function(String data, bool isOutgoing)? callback) {
    _parser.onRawData = callback;
  }

  /// Stream of continuous inventory results.
  ///
  /// Each event is a `List<UhfInventoryResult>` containing all tags
  /// detected in one scan round. Listen to this stream after calling
  /// [startContinuousInventory].
  Stream<List<UhfInventoryResult>> get cinvStream => cinvStreamCtrl.stream;

  // ── Connection ──────────────────────────────────────────────────────────

  /// Connects to the RFID reader.
  ///
  /// Establishes the communication link through the underlying
  /// [CommInterface] and starts listening for incoming data.
  /// The [onError] callback is invoked if a connection error occurs
  /// during or after the connection attempt.
  ///
  /// Returns `true` if the connection was established successfully.
  Future<bool> connect({required void Function(Object?, StackTrace) onError}) async {
    try {
      return await _parser.connect(onError: onError);
    } catch (e, stack) {
      logger.e('Failed to connect to reader', error: e, stackTrace: stack);
      onError(e, stack);
      return false;
    }
  }

  /// Disconnects from the RFID reader.
  ///
  /// Stops the heartbeat timer and closes the communication link.
  /// Safe to call even if already disconnected.
  Future<void> disconnect() async {
    try {
      heartbeat.stop();
      await _parser.disconnect();
    } catch (e, stack) {
      logger.e('Error during disconnect', error: e, stackTrace: stack);
    }
  }

  /// Returns `true` if the reader is currently connected.
  bool isConnected() => _commInterface.isConnected();

  // ── Command helpers ─────────────────────────────────────────────────────

  /// Sends a raw AT command with response handlers.
  ///
  /// This is a low-level method that delegates directly to the parser.
  /// Most users should use the typed methods (e.g., [inventory],
  /// [getOutputPower]) instead.
  ///
  /// - [cmd] -- the AT command string (e.g., `"ATI"`).
  /// - [timeout] -- command timeout in milliseconds.
  /// - [responses] -- handlers for expected response prefixes.
  Future<CmdExitCode> sendCommand(
      String cmd, int timeout, List<ParserResponse> responses) {
    return _parser.sendCommand(cmd, timeout, responses);
  }

  /// Interprets a command exit code and throws the appropriate exception.
  ///
  /// - [CmdExitCode.timeout] -> [ReaderTimeoutException]
  /// - `"<NO TAGS FOUND>"` error -> [ReaderNoTagsException]
  /// - Any other non-OK code -> [ReaderException]
  void _handleExitCode(CmdExitCode code, String error) {
    if (code == CmdExitCode.timeout) {
      throw ReaderTimeoutException("Command timed out! No response from reader.");
    } else if (error == "<NO TAGS FOUND>") {
      throw ReaderNoTagsException("No tags found in range");
    } else if (code != CmdExitCode.ok) {
      throw ReaderException("Command failed with: $error");
    }
  }

  // ── Raw command (for debug/chat interface) ─────────────────────────────

  /// Sends a raw AT command string and collects all response lines.
  ///
  /// Unlike [sendCommand], this method captures all response lines
  /// (regardless of prefix) into a list and returns them along with
  /// a success flag. Useful for debug terminals and chat-style UIs.
  ///
  /// Returns a record with:
  /// - `lines` -- all response lines received before OK/ERROR.
  /// - `ok` -- `true` if the command completed with OK.
  Future<({List<String> lines, bool ok})> sendRawCommand(
      String command, {int timeout = 5000}) async {
    List<String> responseLines = [];

    try {
      CmdExitCode exitCode = await sendCommand(command, timeout, [
        ParserResponse("", (line) {
          responseLines.add(line);
        })
      ]);

      return (
        lines: responseLines,
        ok: exitCode == CmdExitCode.ok,
      );
    } catch (e) {
      return (
        lines: [...responseLines, "ERROR: $e"],
        ok: false,
      );
    }
  }

  // ── Device identification ───────────────────────────────────────────────

  /// Gets the device identification string.
  ///
  /// Sends the `ATI` command and returns the reader's identification
  /// response (typically firmware version, model, and serial number).
  ///
  /// Throws [ReaderTimeoutException] if the reader does not respond.
  Future<String> getDeviceInfo() async {
    String info = "";
    try {
      CmdExitCode exitCode = await sendCommand("ATI", 3000, [
        ParserResponse("", (line) {
          if (info.isNotEmpty) info += "\n";
          info += line;
        })
      ]);
      _handleExitCode(exitCode, info);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException("Failed to get device info: $e");
    }
    return info;
  }

  // ── Feedback (AT+FDB) ──────────────────────────────────────────────────

  /// Triggers a feedback pattern (beep/LED) on the reader.
  ///
  /// [feedbackId] selects the feedback pattern. Typically `1` is a
  /// standard beep. The available patterns depend on the reader model.
  ///
  /// Returns `true` if the reader acknowledged the command.
  /// Throws [ReaderTimeoutException] if the reader does not respond.
  /// Throws [ReaderException] if the reader does not support feedback.
  Future<bool> playFeedback(int feedbackId) async {
    try {
      CmdExitCode exitCode =
          await sendCommand("AT+FDB=$feedbackId", 2000, []);
      _handleExitCode(exitCode, "");
      logger.i('Feedback $feedbackId played successfully');
      return true;
    } on ReaderTimeoutException catch (e) {
      logger.e('Feedback command timed out', error: e);
      throw ReaderTimeoutException(
          'Feedback command timed out. Reader may not support AT+FDB.');
    } on ReaderException catch (e) {
      logger.e('Feedback command failed', error: e);
      throw ReaderException(
          'Feedback command failed: $e. Reader may not have a beeper.');
    } catch (e) {
      logger.e('Unexpected error playing feedback', error: e);
      throw ReaderException('Unexpected error playing feedback: $e');
    }
  }

  // ── Inventory ───────────────────────────────────────────────────────────

  /// Performs a single inventory scan.
  ///
  /// Sends the `AT+INV` command and returns a list of all tags detected
  /// in one scan cycle. Each result includes the tag's EPC, and
  /// optionally TID and RSSI depending on the current [UhfInvSettings].
  ///
  /// Throws [ReaderNoTagsException] if no tags are in range.
  /// Throws [ReaderTimeoutException] if the reader does not respond.
  Future<List<UhfInventoryResult>> inventory() async {
    List<UhfTag> inv = [];
    String error = "";

    // Fetch current inventory settings to know which fields to parse.
    try {
      _invSettings = await getInventorySettings();
    } catch (e) {
      logger.w('Could not read inv settings, using defaults', error: e);
      _invSettings ??= UhfInvSettings(false, false, false, false);
    }

    try {
      CmdExitCode exitCode = await sendCommand("AT+INV", 5000, [
        ParserResponse("+INV", (line) {
          if (line.contains("<")) return; // Skip status messages like "<NO TAGS FOUND>".
          UhfTag? tag = _parseUhfTag(line, _invSettings!);
          if (tag != null) inv.add(tag);
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Inventory failed: $e');
    }

    return inv
        .map((e) => UhfInventoryResult(
              tag: e,
              lastAntenna: invAntenna,
              count: 1,
              timestamp: DateTime.now(),
            ))
        .toList();
  }

  /// Performs a multiplexed (multi-antenna) inventory scan.
  ///
  /// Sends the `AT+MINV` command, which scans across all configured
  /// antenna ports sequentially. Returns results tagged with the
  /// antenna port each tag was detected on.
  ///
  /// Throws [ReaderNoTagsException] if no tags are found on any antenna.
  /// Throws [ReaderTimeoutException] if the reader does not respond.
  Future<List<UhfInventoryResult>> muxInventory() async {
    List<UhfTag> inv = [];
    List<UhfInventoryResult> invResults = [];
    String error = "";

    try {
      _invSettings = await getInventorySettings();
    } catch (e) {
      logger.w('Could not read inv settings, using defaults', error: e);
      _invSettings ??= UhfInvSettings(false, false, false, false);
    }

    try {
      CmdExitCode exitCode = await sendCommand("AT+MINV", 5000, [
        ParserResponse("+MINV", (line) {
          if (line.contains("ROUND FINISHED")) {
            // A round finished for one antenna -- flush accumulated tags.
            int antenna = _parseAntenna(line);
            for (UhfTag e in inv) {
              invResults.add(UhfInventoryResult(
                  tag: e, lastAntenna: antenna, timestamp: DateTime.now()));
            }
            inv.clear();
          } else if (!line.contains("<")) {
            UhfTag? tag = _parseUhfTag(line, _invSettings!);
            if (tag != null) inv.add(tag);
          }
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Mux inventory failed: $e');
    }

    return invResults;
  }

  /// Starts continuous inventory scanning.
  ///
  /// Sends the `AT+CINV` command. Tag results arrive asynchronously
  /// via the [cinvStream] as unsolicited `+CINV` / `+CMINV` events.
  /// Each stream event is a list of tags from one scan round.
  ///
  /// Call [stopContinuousInventory] to stop scanning.
  ///
  /// Throws [ReaderTimeoutException] if the reader does not respond.
  Future<void> startContinuousInventory() async {
    try {
      _invSettings = await getInventorySettings();
    } catch (e) {
      logger.w('Could not read inv settings, using defaults', error: e);
      _invSettings ??= UhfInvSettings(false, false, false, false);
    }

    try {
      CmdExitCode exitCode = await sendCommand("AT+CINV", 1000, []);
      _handleExitCode(exitCode, "");
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to start continuous inventory: $e');
    }
  }

  /// Stops continuous inventory scanning.
  ///
  /// Sends the `AT+BINV` (break inventory) command to halt the
  /// ongoing continuous scan started by [startContinuousInventory].
  Future<void> stopContinuousInventory() async {
    try {
      CmdExitCode exitCode = await sendCommand("AT+BINV", 1000, []);
      _handleExitCode(exitCode, "");
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to stop continuous inventory: $e');
    }
  }

  // ── Power ───────────────────────────────────────────────────────────────

  /// Gets the current output power level(s) in dBm.
  ///
  /// Returns a list of power values, one per antenna port. Also updates
  /// [currentPower] and [antennaCount] as a side effect.
  ///
  /// Throws [ReaderTimeoutException] if the reader does not respond.
  Future<List<int>> getOutputPower() async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+PWR?", 1000, [
        ParserResponse("+PWR", (line) {
          final split = line.split(",");
          antennaCount = split.length;
          currentPower =
              split.map((e) => int.tryParse(e) ?? 0).toList();
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to get output power: $e');
    }
    return currentPower ?? [];
  }

  /// Sets the output power level(s) in dBm.
  ///
  /// [val] is a list of power values. Pass a single value for uniform
  /// power across all antennas, or one value per antenna port for
  /// per-antenna control. Valid range depends on the reader model
  /// (typically 0-30 dBm).
  ///
  /// Throws [ReaderException] if the value is out of range.
  Future<void> setOutputPower(List<int> val) async {
    String error = "";
    try {
      CmdExitCode exitCode =
          await sendCommand("AT+PWR=${val.join(",")}", 1000, [
        ParserResponse("+PWR", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
      currentPower = val;
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to set output power: $e');
    }
  }

  // ── Region ──────────────────────────────────────────────────────────────

  /// Gets the current regulatory region setting.
  ///
  /// Returns the region string (e.g., `"ETSI"`, `"FCC"`, `"ETSI_HIGH"`).
  /// Also updates [currentRegion] as a side effect.
  Future<String> getRegion() async {
    String error = "";
    String? region;

    try {
      CmdExitCode exitCode = await sendCommand("AT+REG?", 1000, [
        ParserResponse("+REG", (line) {
          region = line;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to get region: $e');
    }

    currentRegion = region;
    return region ?? "UNKNOWN";
  }

  /// Sets the regulatory region.
  ///
  /// [region] should be a valid region string (e.g., `"ETSI"`, `"FCC"`).
  /// You can also use [UhfReaderRegion.protocolString] for type safety.
  ///
  /// **Warning**: Changing the region may require a reader reset.
  Future<void> setRegion(String region) async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+REG=$region", 1000, [
        ParserResponse("+REG", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
      currentRegion = region;
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to set region: $e');
    }
  }

  // ── Q Value ─────────────────────────────────────────────────────────────

  /// Gets the current Q value (anti-collision parameter).
  ///
  /// The Q value controls the number of time slots used during
  /// inventory. Higher Q values are better for large tag populations.
  /// Also updates [currentQ], [currentMinQ], and [currentMaxQ].
  ///
  /// Returns the current Q value (defaults to 4 if not set).
  Future<int> getQ() async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+Q?", 1000, [
        ParserResponse("+Q", (line) {
          final splitValues = line.split(",");
          if (splitValues.length != 3) return;
          currentQ = int.tryParse(splitValues[0]);
          currentMinQ = int.tryParse(splitValues[1]);
          currentMaxQ = int.tryParse(splitValues[2]);
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to get Q value: $e');
    }
    return currentQ ?? 4;
  }

  /// Sets the Q value with minimum and maximum range.
  ///
  /// - [val] -- the starting Q value.
  /// - [qMin] -- the minimum Q value the reader may adapt to.
  /// - [qMax] -- the maximum Q value the reader may adapt to.
  ///
  /// Typical range is 0-15. Use higher values for larger tag populations.
  Future<void> setQ(int val, int qMin, int qMax) async {
    String error = "";
    try {
      CmdExitCode exitCode =
          await sendCommand("AT+Q=$val,$qMin,$qMax", 1000, [
        ParserResponse("+Q", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
      currentQ = val;
      currentMinQ = qMin;
      currentMaxQ = qMax;
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to set Q value: $e');
    }
  }

  // ── Antenna ─────────────────────────────────────────────────────────────

  /// Gets the currently active inventory antenna port.
  ///
  /// Returns the 1-based antenna port number. Also updates [invAntenna].
  Future<int> getInvAntenna() async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+ANT?", 5000, [
        ParserResponse("+ANT", (line) {
          invAntenna = int.tryParse(line) ?? invAntenna;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to get antenna: $e');
    }
    return invAntenna;
  }

  /// Sets the active inventory antenna port.
  ///
  /// [val] is the 1-based antenna port number. The valid range depends
  /// on the reader model (e.g., 1-4 for a 4-port reader).
  Future<void> setInvAntenna(int val) async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+ANT=$val", 1000, [
        ParserResponse("+ANT", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
      invAntenna = val;
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to set antenna: $e');
    }
  }

  // ── Inventory Settings ──────────────────────────────────────────────────

  /// Gets the current inventory format settings.
  ///
  /// Returns a [UhfInvSettings] describing which optional fields
  /// (ONT, RSSI, TID, FastStart) are enabled in inventory responses.
  /// The result is also cached internally for use by inventory parsing.
  Future<UhfInvSettings> getInventorySettings() async {
    String error = "";
    UhfInvSettings? settings;

    try {
      CmdExitCode exitCode = await sendCommand("AT+INVS?", 1000, [
        ParserResponse("+INVS", (line) {
          List<bool> values =
              line.split(",").map((e) => (e == '1')).toList();
          if (values.length < 3) {
            error = line;
            return;
          }
          settings = UhfInvSettings(
            values[0],
            values[1],
            values[2],
            values.length > 3 ? values[3] : false,
          );
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to get inventory settings: $e');
    }

    if (settings == null) {
      throw ReaderException("Failed to parse inventory settings from: $error");
    }
    _invSettings = settings;
    return settings!;
  }

  /// Sets the inventory format settings.
  ///
  /// Controls which optional fields are included in inventory responses.
  /// See [UhfInvSettings] for the available options.
  Future<void> setInventorySettings(UhfInvSettings invSettings) async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand(
          "AT+INVS=${invSettings.toProtocolString()}", 1000, [
        ParserResponse("+INVS", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
      _invSettings = invSettings;
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to set inventory settings: $e');
    }
  }

  // ── Heartbeat ───────────────────────────────────────────────────────────

  /// Starts heartbeat monitoring for connection aliveness.
  ///
  /// The reader sends periodic `+HBT` unsolicited responses at the
  /// specified interval. If a heartbeat is not received within
  /// `seconds + 2` seconds, the [onTimeout] callback fires.
  ///
  /// - [seconds] -- heartbeat interval in seconds (sent to reader).
  /// - [onHbt] -- called each time a heartbeat is received.
  /// - [onTimeout] -- called if a heartbeat is missed (connection may be lost).
  Future<void> startHeartBeat(
      int seconds, Function onHbt, Function onTimeout) async {
    heartbeat.stop();
    try {
      CmdExitCode exitCode =
          await sendCommand("AT+HBT=$seconds", 1000, []);
      _handleExitCode(exitCode, "");
      // Add 2000ms grace period to account for transmission delay.
      heartbeat.start(seconds * 1000 + 2000, onHbt, onTimeout);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to start heartbeat: $e');
    }
  }

  /// Stops heartbeat monitoring.
  ///
  /// Sends `AT+HBT=0` to disable the reader's periodic heartbeat
  /// and stops the local timeout timer.
  Future<void> stopHeartBeat() async {
    heartbeat.stop();
    try {
      CmdExitCode exitCode = await sendCommand("AT+HBT=0", 1000, []);
      _handleExitCode(exitCode, "");
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to stop heartbeat: $e');
    }
  }

  // ── Read / Write Tag Data ──────────────────────────────────────────────

  /// Reads data from a tag's memory bank.
  ///
  /// - [memBank] -- the memory bank to read (e.g., `"EPC"`, `"TID"`, `"USR"`).
  /// - [start] -- the starting word offset within the memory bank.
  /// - [length] -- the number of words to read.
  /// - [mask] -- optional EPC mask to select a specific tag.
  ///
  /// Returns a list of [UhfRwResult], one per tag that responded.
  /// Each result contains the tag's EPC, a success flag, and the
  /// read data as a [Uint8List].
  ///
  /// Throws [ReaderNoTagsException] if no tags are in range.
  Future<List<UhfRwResult>> readTag(
      String memBank, int start, int length, {String? mask}) async {
    List<UhfRwResult> res = [];
    String error = "";
    String maskString = mask == null ? "" : ",$mask";

    try {
      CmdExitCode exitCode = await sendCommand(
          "AT+READ=$memBank,$start,$length$maskString", 2000, [
        ParserResponse("+READ", (line) {
          if (line.contains("<NO TAGS FOUND>")) {
            error = line;
            return;
          }
          // Parse response: "EPC,OK,DATA" or "EPC,ERROR"
          List<String> tokens = line.split(',');
          if (tokens.length >= 2 && tokens[1] == "OK") {
            res.add(UhfRwResult(
                tokens[0],
                true,
                tokens.length > 2
                    ? tokens[2].hexStringToBytes()
                    : Uint8List(0)));
          } else {
            res.add(UhfRwResult(tokens[0], false, Uint8List(0)));
          }
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to read tag: $e');
    }

    return res;
  }

  /// Writes data to a tag's memory bank.
  ///
  /// - [memBank] -- the memory bank to write (e.g., `"EPC"`, `"USR"`).
  /// - [start] -- the starting word offset within the memory bank.
  /// - [data] -- the hex string data to write (e.g., `"DEADBEEF"`).
  /// - [mask] -- optional EPC mask to select a specific tag.
  ///
  /// Returns a list of [UhfRwResult], one per tag that was written to.
  ///
  /// Throws [ReaderException] if [data] is not a valid hex string.
  /// Throws [ReaderNoTagsException] if no tags are in range.
  Future<List<UhfRwResult>> writeTag(
      String memBank, int start, String data, {String? mask}) async {
    if (!hexRegEx.hasMatch(data)) {
      throw ReaderException("Data must be a hex string");
    }

    String error = "";
    String maskString = mask == null ? "" : ",$mask";
    List<UhfRwResult> res = [];

    try {
      CmdExitCode exitCode = await sendCommand(
          "AT+WRT=$memBank,$start,$data$maskString", 2000, [
        ParserResponse("+WRT", (line) {
          if (line.contains("<NO TAGS FOUND>")) {
            error = line;
            return;
          }
          // Parse response: "EPC,OK" or "EPC,ERROR_CODE"
          List<String> tokens = line.split(',');
          final isOk = tokens.last == "OK";
          res.add(UhfRwResult(tokens.first, isOk, Uint8List(0)));
          if (!isOk) error = tokens.last;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to write tag: $e');
    }

    if (error.isNotEmpty) {
      throw ReaderException(error);
    }
    return res;
  }

  // ── Mask ────────────────────────────────────────────────────────────────

  /// Sets a byte mask for inventory filtering.
  ///
  /// Only tags whose memory matches the specified [mask] pattern will
  /// be included in subsequent inventory operations.
  ///
  /// - [memBank] -- the memory bank to match against (e.g., `"EPC"`).
  /// - [start] -- the starting byte offset for the mask.
  /// - [mask] -- the hex string mask pattern (e.g., `"E200"`).
  ///
  /// Throws [ReaderException] if [mask] is not a valid hex string.
  Future<void> setByteMask(String memBank, int start, String mask) async {
    if (!hexRegEx.hasMatch(mask)) {
      throw ReaderException("Mask must be a hex string");
    }
    String error = "";
    try {
      CmdExitCode exitCode =
          await sendCommand("AT+MSK=$memBank,$start,$mask", 1000, [
        ParserResponse("+MSK", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to set mask: $e');
    }
  }

  /// Clears the inventory filter mask.
  ///
  /// After calling this, all tags will be included in inventory
  /// operations regardless of their memory contents.
  Future<void> clearByteMask() async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+MSK=OFF", 1000, [
        ParserResponse("+MSK", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to clear mask: $e');
    }
  }

  // ── Lock / Unlock / Kill ────────────────────────────────────────────────

  /// Locks a tag's memory bank to prevent writing.
  ///
  /// - [memBank] -- the memory bank to lock (e.g., `"EPC"`, `"USR"`).
  /// - [password] -- the 8-character hex access password (e.g., `"00000000"`).
  /// - [mask] -- optional EPC mask to select a specific tag.
  ///
  /// Throws [ReaderException] if the lock operation fails.
  Future<void> lockMembank(String memBank, String password,
      {String? mask}) async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand(
          "AT+LCK=$memBank,$password${mask != null ? ",$mask" : ''}",
          1000, [
        ParserResponse("+LCK", (line) {
          final split = line.split(",");
          if (split.last != "OK") error = split.last;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to lock membank: $e');
    }
    if (error.isNotEmpty) throw ReaderException(error);
  }

  /// Unlocks a tag's memory bank to allow writing.
  ///
  /// - [memBank] -- the memory bank to unlock.
  /// - [password] -- the 8-character hex access password.
  /// - [mask] -- optional EPC mask to select a specific tag.
  ///
  /// Throws [ReaderException] if the unlock operation fails.
  Future<void> unlockMembank(String memBank, String password,
      {String? mask}) async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand(
          "AT+ULCK=$memBank,$password${mask != null ? ",$mask" : ''}",
          1000, [
        ParserResponse("+ULCK", (line) {
          final split = line.split(",");
          if (split.last != "OK") error = split.last;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to unlock membank: $e');
    }
    if (error.isNotEmpty) throw ReaderException(error);
  }

  /// Permanently kills (disables) a tag. **This is irreversible.**
  ///
  /// - [password] -- the 8-character hex kill password.
  /// - [mask] -- optional EPC mask to select a specific tag.
  ///
  /// After a successful kill, the tag will no longer respond to any
  /// commands or inventory scans.
  ///
  /// Throws [ReaderException] if the kill operation fails.
  Future<void> killTag(String password, {String? mask}) async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand(
          "AT+KILL=$password${mask != null ? ",$mask" : ''}", 1000, [
        ParserResponse("+KILL", (line) {
          final split = line.split(",");
          if (split.last != "OK") error = split.last;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to kill tag: $e');
    }
    if (error.isNotEmpty) throw ReaderException(error);
  }

  // ── Session / RF Mode ──────────────────────────────────────────────────

  /// Gets the current Gen2 session value.
  ///
  /// The session controls how tags handle repeated inventories.
  /// Returns a string like `"0"`, `"1"`, `"2"`, or `"3"`.
  Future<String> getSession() async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+SES?", 1000, [
        ParserResponse("+SES", (line) {
          currentSession = line;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to get session: $e');
    }
    return currentSession ?? "UNKNOWN";
  }

  /// Sets the Gen2 session value.
  ///
  /// [value] should be `"0"`, `"1"`, `"2"`, or `"3"`. The session
  /// affects how tags behave during repeated inventory rounds:
  /// - Session 0: Tags reset immediately (good for detecting all tags).
  /// - Session 1-3: Tags persist their state longer (good for counting).
  Future<void> setSession(String value) async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+SES=$value", 1000, [
        ParserResponse("+SES", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
      currentSession = value;
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to set session: $e');
    }
  }

  /// Gets the current RF modulation mode.
  ///
  /// The RF mode controls the modulation scheme used for tag
  /// communication. Different modes trade off range vs. speed.
  /// Returns the mode number (reader-model dependent).
  Future<int> getRfMode() async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+RFM?", 1000, [
        ParserResponse("+RFM", (line) {
          currentRfMode = int.tryParse(line) ?? currentRfMode;
        })
      ]);
      _handleExitCode(exitCode, error);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to get RF mode: $e');
    }
    return currentRfMode ?? 0;
  }

  /// Sets the RF modulation mode.
  ///
  /// [value] is the mode number. Available modes depend on the reader
  /// model and the configured region. Consult the reader's documentation
  /// for valid values.
  Future<void> setRfMode(int value) async {
    String error = "";
    try {
      CmdExitCode exitCode = await sendCommand("AT+RFM=$value", 1000, [
        ParserResponse("+RFM", (line) {
          error = line;
        })
      ]);
      _handleExitCode(exitCode, error);
      currentRfMode = value;
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to set RF mode: $e');
    }
  }

  // ── Reset ──────────────────────────────────────────────────────────────

  /// Resets the reader hardware.
  ///
  /// Sends the `AT+RST` command to perform a hardware reset.
  /// The reader will restart and the connection may need to be
  /// re-established depending on the transport.
  Future<void> resetReader() async {
    try {
      await sendCommand("AT+RST", 3000, []);
    } catch (e) {
      throw ReaderException('Failed to reset reader: $e');
    }
  }

  // ── Internal parsing helpers ────────────────────────────────────────────

  /// Handles `+CINV` and `+CMINV` unsolicited response lines during
  /// continuous inventory.
  ///
  /// Tags are accumulated in [_cinv] until a "ROUND FINISHED" line
  /// arrives, at which point the batch is emitted on [cinvStream]
  /// with the antenna number extracted from the round-finished message.
  void _handleCinvUrc(String line) {
    if (_invSettings == null) return;

    try {
      if (line.contains("ROUND FINISHED")) {
        // Round complete -- emit accumulated tags as a batch.
        List<UhfInventoryResult> inv = [];
        inv.addAll(_cinv);
        _cinv.clear();

        int antenna = _parseAntenna(line);
        for (UhfInventoryResult entry in inv) {
          entry.lastAntenna = antenna;
        }

        cinvStreamCtrl.add(inv);
        return;
      } else if (line.contains("<")) {
        // Skip status/info messages (e.g., "<NO TAGS FOUND>").
        return;
      }

      // Parse the tag data from the line (strip the "+CINV: " prefix).
      UhfTag? tag = _parseUhfTag(line.split(": ").last, _invSettings!);
      if (tag == null) return;

      _cinv.add(UhfInventoryResult(
        tag: tag,
        lastAntenna: 0, // Will be set when "ROUND FINISHED" arrives.
        timestamp: DateTime.now(),
      ));
    } catch (e) {
      logger.e('Error parsing CINV URC', error: e);
    }
  }

  /// Handles `+CINVR` unsolicited response lines (inventory reports
  /// with per-tag antenna information).
  ///
  /// Unlike `+CINV`, report lines include the antenna number inline,
  /// so each tag is parsed with its antenna immediately.
  void _handleCinvReportUrc(String line) {
    if (_invSettings == null) return;

    try {
      if (line.contains("<")) return;

      UhfInventoryResult? result =
          _parseInventoryReport(line.split(": ").last, _invSettings!);
      if (result == null) return;

      _cinv.add(result);
    } catch (e) {
      logger.e('Error parsing CINVR URC', error: e);
    }
  }

  /// Extracts the antenna number from a "ROUND FINISHED" line.
  ///
  /// The line format is typically:
  /// `+CINV: <ROUND FINISHED,ANT=1>` or similar.
  /// Returns 0 if the antenna number cannot be parsed.
  int _parseAntenna(String line) {
    try {
      if (!line.contains("ANT")) return 0;
      return int.parse(
          line.split(',').last.split('=').last.replaceAll(">", ""),
          radix: 10);
    } catch (e) {
      logger.e('Error parsing antenna from line: $line', error: e);
      return 0;
    }
  }

  /// Parses a comma-separated tag data string into a [UhfTag].
  ///
  /// The expected format depends on the current [settings]:
  /// - EPC only: `"E200..."` (1 token)
  /// - EPC + RSSI: `"E200...,-45"` (2 tokens)
  /// - EPC + TID: `"E200...,E280..."` (2 tokens)
  /// - EPC + TID + RSSI: `"E200...,E280...,-45"` (3 tokens)
  ///
  /// Returns `null` if the line cannot be parsed with the given settings.
  UhfTag? _parseUhfTag(String inv, UhfInvSettings settings) {
    try {
      List<String> tokens = inv.split(',');

      if (!settings.tid && !settings.rssi && tokens.length == 1) {
        return UhfTag(tokens.first, '', 0);
      } else if (!settings.tid && settings.rssi && tokens.length == 2) {
        return UhfTag(tokens.first, '', int.tryParse(tokens.last) ?? 0);
      } else if (settings.tid && !settings.rssi && tokens.length == 2) {
        return UhfTag(tokens.first, tokens.last, 0);
      } else if (settings.tid && settings.rssi && tokens.length == 3) {
        return UhfTag(tokens[0], tokens[1], int.tryParse(tokens[2]) ?? 0);
      }
    } catch (e) {
      logger.e('Error parsing UHF tag from: $inv', error: e);
    }
    return null;
  }

  /// Parses an inventory report line that includes antenna information.
  ///
  /// Report lines have the same tag fields as regular inventory lines,
  /// but with an additional antenna number appended at the end.
  /// Returns `null` if the line cannot be parsed.
  UhfInventoryResult? _parseInventoryReport(
      String report, UhfInvSettings settings) {
    try {
      List<String> tokens = report.split(',');
      UhfTag? tag;

      if (!settings.tid && !settings.rssi && tokens.length == 2) {
        tag = UhfTag(tokens[0], '', 0);
      } else if (!settings.tid && settings.rssi && tokens.length == 3) {
        tag = UhfTag(tokens[0], '', int.tryParse(tokens[1]) ?? 0);
      } else if (settings.tid && !settings.rssi && tokens.length == 3) {
        tag = UhfTag(tokens[0], tokens.last, 0);
      } else if (settings.tid && settings.rssi && tokens.length == 4) {
        tag = UhfTag(tokens[0], tokens[1], int.tryParse(tokens[2]) ?? 0);
      }

      if (tag != null) {
        return UhfInventoryResult(
          tag: tag,
          lastAntenna: int.tryParse(tokens.last) ?? 1,
          count: 1,
          timestamp: DateTime.now(),
        );
      }
    } catch (e) {
      logger.e('Error parsing inventory report from: $report', error: e);
    }
    return null;
  }
}
