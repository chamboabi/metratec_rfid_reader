import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';

/// Exit code returned by AT commands after they complete.
///
/// Every command sent via [Parser.sendCommand] eventually completes
/// with one of these codes, indicating whether the reader responded
/// successfully, reported an error, or timed out.
enum CmdExitCode {
  /// The reader responded with "OK" -- command succeeded.
  ok,

  /// The reader responded with "ERROR" -- command failed.
  error,

  /// No response was received within the timeout period.
  timeout,

  /// The command was canceled before completion.
  canceled,
}

/// Defines a response handler that matches incoming lines by prefix.
///
/// When the parser receives a line that starts with [prefix], it
/// invokes [dataCb] with the line data (prefix stripped). This is
/// used to capture structured response data from AT commands.
///
/// Example: A `ParserResponse("+INV", callback)` will match lines
/// like `+INV: E200...` and call `callback("E200...")`.
class ParserResponse {
  /// The prefix string this handler matches against incoming lines.
  String prefix;

  /// Callback invoked with the line data when the prefix matches.
  /// The prefix and separator (": ") are stripped before calling.
  void Function(String) dataCb;

  /// Creates a response handler that matches lines starting with [prefix]
  /// and delivers the data portion to [dataCb].
  ParserResponse(this.prefix, this.dataCb);
}

/// Internal bookkeeping for a running command.
///
/// Groups the response handlers for a command together with a
/// [Completer] that resolves when the command terminates (OK/ERROR/timeout).
class ParserResponseEntry {
  /// Response handlers registered for this command.
  List<ParserResponse> responses;

  /// Completer that resolves with the command's [CmdExitCode]
  /// when the command terminates.
  Completer<CmdExitCode> completer = Completer();

  /// Creates an entry with the given [responses] handlers.
  ParserResponseEntry(this.responses);
}

/// Abstract command/response parser for RFID reader communication.
///
/// The parser sits between the [CommInterface] (raw bytes) and the
/// high-level reader API ([UhfReaderAt]). It handles:
///
/// 1. **Sending commands** -- writes an AT command string + EOL to the
///    communication interface and starts a timeout timer.
/// 2. **Receiving responses** -- subscribes to the comm interface's byte
///    stream, splits incoming data into lines, and dispatches each line
///    to the appropriate handler.
/// 3. **Unsolicited events** -- supports registering handlers for
///    asynchronous events (e.g., heartbeat `+HBT`, continuous inventory
///    `+CINV`) that arrive outside of a command/response cycle.
/// 4. **Timeouts** -- automatically completes a command with
///    [CmdExitCode.timeout] if no terminating response arrives in time.
///
/// Only **one command** can be running at a time. Attempting to send a
/// second command while one is in progress will throw an exception.
///
/// Subclasses must implement [handleRxLine] to define protocol-specific
/// line processing (e.g., [ParserAt] for the AT protocol).
abstract class Parser {
  /// The underlying communication interface for sending/receiving bytes.
  final CommInterface _commInterface;

  /// Subscription to the comm interface's receive stream.
  StreamSubscription? _rxSub;

  /// The currently running command entry, or `null` if idle.
  ///
  /// When a command is in progress, incoming lines are checked against
  /// this entry's response handlers. When `null`, only registered
  /// unsolicited events are processed.
  ParserResponseEntry? responseEntry;

  /// Timer for the current command's timeout. Canceled when the
  /// command completes or is explicitly finished.
  Timer? _cmdTimer;

  /// List of registered unsolicited event handlers.
  ///
  /// These are checked against every incoming line, even when no
  /// command is running. Used for heartbeat, continuous inventory,
  /// and other asynchronous reader events.
  final List<ParserResponse> events = [];

  /// End-of-line character(s) appended to each outgoing command.
  /// For the Metratec AT protocol, this is `"\r"` (carriage return).
  final String _eol;

  /// Optional callback for raw data logging.
  ///
  /// When set, every sent command and received line is passed to this
  /// callback. The [isOutgoing] parameter is `true` for sent commands,
  /// `false` for received lines. Useful for debug/chat views.
  void Function(String data, bool isOutgoing)? onRawData;

  /// Creates a parser that communicates over [_commInterface] and
  /// appends [_eol] to each outgoing command.
  Parser(this._commInterface, this._eol);

  /// Connects the communication interface and starts listening for data.
  ///
  /// Incoming bytes are decoded from ASCII, split into lines by
  /// [LineSplitter], and dispatched to [handleRxLine] one at a time.
  /// Empty lines are silently skipped for raw data logging.
  ///
  /// The [onError] callback is invoked if a connection error occurs
  /// or if an exception is thrown during line handling.
  ///
  /// Throws if already connected.
  Future<bool> connect({required void Function(Object?, StackTrace) onError}) async {
    if (_commInterface.isConnected()) {
      throw Exception("Already connected");
    }

    _commInterface.onSocketException = onError;

    if (!await _commInterface.connect(onError: onError)) {
      return false;
    }

    // Subscribe to the receive stream: decode bytes -> split into lines -> handle.
    _rxSub = _commInterface.rxStream
        .map((e) => String.fromCharCodes(e))
        .transform(const LineSplitter())
        .listen((line) {
      try {
        // Log incoming raw data for debug/chat view.
        if (line.isNotEmpty) {
          onRawData?.call(line, false);
        }
        handleRxLine(line);
      } catch (e) {
        // Catch any errors in line handling to prevent stream crash.
        onError(e, StackTrace.current);
      }
    });

    return true;
  }

  /// Disconnects from the communication interface.
  ///
  /// Cancels the receive stream subscription and closes the underlying
  /// transport. Safe to call even if already disconnected.
  Future<void> disconnect() async {
    try {
      await _rxSub?.cancel();
    } catch (_) {}
    try {
      await _commInterface.disconnect();
    } catch (_) {}
    _rxSub = null;
  }

  /// Sends an AT command to the reader and waits for a response.
  ///
  /// - [cmd] is the AT command string (e.g., `"ATI"`, `"AT+INV"`).
  /// - [timeout] is the maximum time to wait in milliseconds. If the
  ///   command does not complete within this time, it resolves with
  ///   [CmdExitCode.timeout]. Use 0 for no timeout.
  /// - [responses] is a list of [ParserResponse] handlers to match
  ///   against incoming response lines for this command.
  ///
  /// Returns a [Future] that completes with the command's [CmdExitCode].
  ///
  /// Throws if another command is already running (only one command
  /// at a time is allowed), or if writing to the comm interface fails.
  Future<CmdExitCode> sendCommand(
      String cmd, int timeout, List<ParserResponse> responses) async {
    if (responseEntry != null) {
      throw Exception("Another command is already running!");
    }

    responseEntry = ParserResponseEntry(responses);

    // Log outgoing command for debug/chat view.
    onRawData?.call(cmd, true);

    // Write the command + EOL to the communication interface.
    if (_commInterface.write(Uint8List.fromList("$cmd$_eol".codeUnits)) == false) {
      responseEntry = null;
      throw Exception("Sending command failed! Check connection.");
    }

    // Start a timeout timer if a timeout value is specified.
    if (timeout > 0) {
      _cmdTimer = Timer(Duration(milliseconds: timeout), () {
        finishCommand(CmdExitCode.timeout);
      });
    }

    return responseEntry!.completer.future;
  }

  /// Completes the currently running command with the given [code].
  ///
  /// Cancels the timeout timer and resolves the command's completer.
  /// After this call, [responseEntry] is `null` and a new command
  /// can be sent.
  void finishCommand(CmdExitCode code) {
    _cmdTimer?.cancel();
    _cmdTimer = null;

    responseEntry?.completer.complete(code);
    responseEntry = null;
  }

  /// Registers a handler for unsolicited events from the reader.
  ///
  /// Unsolicited events are lines that arrive outside of a command/response
  /// cycle (e.g., `+HBT` heartbeat pings, `+CINV` continuous inventory
  /// tag reports). The [event] handler is checked against every incoming
  /// line by prefix, even when no command is running.
  void registerEvent(ParserResponse event) {
    events.add(event);
  }

  /// Processes a single received line from the reader.
  ///
  /// Subclasses implement this to define protocol-specific behavior:
  /// checking for unsolicited events, command termination markers
  /// (OK/ERROR), and prefix-matched response data.
  void handleRxLine(String line);
}
