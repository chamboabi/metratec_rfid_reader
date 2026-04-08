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

/// Settings for UHF inventory format.
class UhfInvSettings {
  bool ont;
  bool rssi;
  bool tid;
  bool fastStart;

  UhfInvSettings(this.ont, this.rssi, this.tid, this.fastStart);

  String toProtocolString() =>
      [ont, rssi, tid, fastStart].map((e) => e.toProtocolString()).join(",");

  @override
  String toString() => "ONT=$ont;RSSI=$rssi;TID=$tid;FS=$fastStart";
}

/// Result of a tag read/write operation.
class UhfRwResult {
  String epc;
  bool ok;
  Uint8List data;

  UhfRwResult(this.epc, this.ok, this.data);

  @override
  String toString() => "EPC=$epc;OK=$ok,DATA=$data";
}

/// Available UHF memory banks for the AT protocol.
enum UhfMemoryBank {
  pc,
  epc,
  tid,
  usr;

  String get protocolString => switch (this) {
        UhfMemoryBank.pc => "PC",
        UhfMemoryBank.epc => "EPC",
        UhfMemoryBank.tid => "TID",
        UhfMemoryBank.usr => "USR",
      };
}

/// UHF reader regions.
enum UhfReaderRegion {
  etsi,
  etsiHigh,
  fcc;

  String get protocolString => switch (this) {
        UhfReaderRegion.etsi => "ETSI",
        UhfReaderRegion.etsiHigh => "ETSI_HIGH",
        UhfReaderRegion.fcc => "FCC",
      };
}

/// UHF AT Protocol Reader implementation.
///
/// This class provides a high-level API for communicating with
/// Metratec UHF RFID readers using the AT command protocol.
/// It integrates the Web Serial API for browser-based communication.
class UhfReaderAt {
  final CommInterface _commInterface;
  final ParserAt _parser;
  final Logger logger = Logger();
  final RegExp hexRegEx = RegExp(r"^[a-fA-F0-9]+$");

  /// Heartbeat timer for connection monitoring.
  final Heartbeat heartbeat = Heartbeat();

  /// Stream controller for continuous inventory results.
  final StreamController<List<UhfInventoryResult>> cinvStreamCtrl =
      StreamController.broadcast();

  UhfInvSettings? _invSettings;
  final List<UhfInventoryResult> _cinv = [];

  // Current reader state
  String? currentRegion;
  List<int>? currentPower;
  int? currentQ;
  int? currentMinQ;
  int? currentMaxQ;
  int invAntenna = 1;
  int antennaCount = 1;
  String? currentSession;
  int? currentRfMode;
  List<int> currentMuxAntenna = [1];

  UhfReaderAt(this._commInterface)
      : _parser = ParserAt(_commInterface, "\r") {
    // Register unsolicited event handlers
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

  /// Set callback for raw data logging (for the debug chat view).
  set onRawData(void Function(String data, bool isOutgoing)? callback) {
    _parser.onRawData = callback;
  }

  /// Get the continuous inventory stream.
  Stream<List<UhfInventoryResult>> get cinvStream => cinvStreamCtrl.stream;

  // ── Connection ──────────────────────────────────────────────────────────

  /// Connect to the reader via Web Serial.
  Future<bool> connect({required void Function(Object?, StackTrace) onError}) async {
    try {
      return await _parser.connect(onError: onError);
    } catch (e, stack) {
      logger.e('Failed to connect to reader', error: e, stackTrace: stack);
      onError(e, stack);
      return false;
    }
  }

  /// Disconnect from the reader.
  Future<void> disconnect() async {
    try {
      heartbeat.stop();
      await _parser.disconnect();
    } catch (e, stack) {
      logger.e('Error during disconnect', error: e, stackTrace: stack);
    }
  }

  /// Check if the reader is connected.
  bool isConnected() => _commInterface.isConnected();

  // ── Command helpers ─────────────────────────────────────────────────────

  /// Send a raw AT command and return the exit code.
  Future<CmdExitCode> sendCommand(
      String cmd, int timeout, List<ParserResponse> responses) {
    return _parser.sendCommand(cmd, timeout, responses);
  }

  /// Handle exit codes from commands, throwing appropriate exceptions.
  void _handleExitCode(CmdExitCode code, String error) {
    if (code == CmdExitCode.timeout) {
      throw ReaderTimeoutException("Command timed out! No response from reader.");
    } else if (error == "<NO TAGS FOUND>") {
      throw ReaderNoTagsException("No tags found in range");
    } else if (code != CmdExitCode.ok) {
      throw ReaderException("Command failed with: $error");
    }
  }

  // ── Raw command (for chat interface) ────────────────────────────────────

  /// Send a raw AT command string and collect all response lines.
  /// Returns a list of response lines and whether the command succeeded.
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

  /// Get device identification string (ATI command).
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

  /// Play feedback sound/LED on the reader.
  /// [feedbackId] selects the feedback pattern (1 = standard beep).
  /// Returns true if the reader acknowledged the command.
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

  /// Perform a single inventory scan.
  Future<List<UhfInventoryResult>> inventory() async {
    List<UhfTag> inv = [];
    String error = "";

    try {
      _invSettings = await getInventorySettings();
    } catch (e) {
      logger.w('Could not read inv settings, using defaults', error: e);
      _invSettings ??= UhfInvSettings(false, false, false, false);
    }

    try {
      CmdExitCode exitCode = await sendCommand("AT+INV", 5000, [
        ParserResponse("+INV", (line) {
          if (line.contains("<")) return;
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

  /// Perform a multiplexed inventory scan.
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

  /// Start continuous inventory.
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

  /// Stop continuous inventory.
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

  /// Get the current output power value(s).
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

  /// Set the output power.
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

  /// Get the current region setting.
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

  /// Set the region (e.g., "ETSI", "FCC").
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

  /// Get the current Q value.
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

  /// Set Q value with range.
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

  /// Get the current inventory antenna.
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

  /// Set the inventory antenna.
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

  /// Get current inventory settings (ONT, RSSI, TID, FastStart).
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

  /// Set inventory settings.
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

  /// Start heartbeat monitoring.
  Future<void> startHeartBeat(
      int seconds, Function onHbt, Function onTimeout) async {
    heartbeat.stop();
    try {
      CmdExitCode exitCode =
          await sendCommand("AT+HBT=$seconds", 1000, []);
      _handleExitCode(exitCode, "");
      heartbeat.start(seconds * 1000 + 2000, onHbt, onTimeout);
    } on ReaderException {
      rethrow;
    } catch (e) {
      throw ReaderException('Failed to start heartbeat: $e');
    }
  }

  /// Stop heartbeat monitoring.
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

  /// Read data from a tag memory bank.
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

  /// Write data to a tag memory bank.
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

  /// Set a byte mask for inventory filtering.
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

  /// Clear the byte mask.
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

  /// Lock a memory bank.
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

  /// Unlock a memory bank.
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

  /// Kill a tag.
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

  /// Get the current session value.
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

  /// Set the session value.
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

  /// Get the current RF mode.
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

  /// Set the RF mode.
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

  /// Reset the reader.
  Future<void> resetReader() async {
    try {
      await sendCommand("AT+RST", 3000, []);
    } catch (e) {
      throw ReaderException('Failed to reset reader: $e');
    }
  }

  // ── Internal parsing helpers ────────────────────────────────────────────

  void _handleCinvUrc(String line) {
    if (_invSettings == null) return;

    try {
      if (line.contains("ROUND FINISHED")) {
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
        return;
      }

      UhfTag? tag = _parseUhfTag(line.split(": ").last, _invSettings!);
      if (tag == null) return;

      _cinv.add(UhfInventoryResult(
        tag: tag,
        lastAntenna: 0,
        timestamp: DateTime.now(),
      ));
    } catch (e) {
      logger.e('Error parsing CINV URC', error: e);
    }
  }

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
