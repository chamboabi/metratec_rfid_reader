import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:metratec_rfid_reader/src/comm/comm_interface.dart';

/// Exit code for AT commands.
enum CmdExitCode {
  ok,
  error,
  timeout,
  canceled,
}

/// A response handler for parser responses.
class ParserResponse {
  /// Prefix the response has to contain.
  String prefix;

  /// Callback for the response data.
  void Function(String) dataCb;

  ParserResponse(this.prefix, this.dataCb);
}

/// Entry for a running command with its response handlers.
class ParserResponseEntry {
  List<ParserResponse> responses;
  Completer<CmdExitCode> completer = Completer();

  ParserResponseEntry(this.responses);
}

/// Abstract parser for RFID reader command-response communication.
/// Handles sending commands, timeouts, and event registration.
abstract class Parser {
  final CommInterface _commInterface;
  StreamSubscription? _rxSub;

  /// Running command entry. Null when idle.
  ParserResponseEntry? responseEntry;

  Timer? _cmdTimer;

  /// List of registered unsolicited events.
  final List<ParserResponse> events = [];

  /// End of line character(s) for the protocol.
  final String _eol;

  /// Optional callback for raw data logging (for the chat/debug view).
  void Function(String data, bool isOutgoing)? onRawData;

  Parser(this._commInterface, this._eol);

  /// Connect the communication interface.
  Future<bool> connect({required void Function(Object?, StackTrace) onError}) async {
    if (_commInterface.isConnected()) {
      throw Exception("Already connected");
    }

    _commInterface.onSocketException = onError;

    if (!await _commInterface.connect(onError: onError)) {
      return false;
    }

    _rxSub = _commInterface.rxStream
        .map((e) => String.fromCharCodes(e))
        .transform(const LineSplitter())
        .listen((line) {
      try {
        // Log incoming raw data for debug view
        if (line.isNotEmpty) {
          onRawData?.call(line, false);
        }
        handleRxLine(line);
      } catch (e) {
        // Catch any errors in line handling to prevent stream crash
        onError(e, StackTrace.current);
      }
    });

    return true;
  }

  /// Disconnect from the communication interface.
  Future<void> disconnect() async {
    try {
      await _rxSub?.cancel();
    } catch (_) {}
    try {
      await _commInterface.disconnect();
    } catch (_) {}
    _rxSub = null;
  }

  /// Send a command to the reader.
  /// [cmd] is the AT command string.
  /// [timeout] is the command timeout in milliseconds.
  /// [responses] are the expected response handlers.
  Future<CmdExitCode> sendCommand(
      String cmd, int timeout, List<ParserResponse> responses) async {
    if (responseEntry != null) {
      throw Exception("Another command is already running!");
    }

    responseEntry = ParserResponseEntry(responses);

    // Log outgoing command for debug view
    onRawData?.call(cmd, true);

    if (_commInterface.write(Uint8List.fromList("$cmd$_eol".codeUnits)) == false) {
      responseEntry = null;
      throw Exception("Sending command failed! Check connection.");
    }

    if (timeout > 0) {
      _cmdTimer = Timer(Duration(milliseconds: timeout), () {
        finishCommand(CmdExitCode.timeout);
      });
    }

    return responseEntry!.completer.future;
  }

  /// Finish the running command with the given exit code.
  void finishCommand(CmdExitCode code) {
    _cmdTimer?.cancel();
    _cmdTimer = null;

    responseEntry?.completer.complete(code);
    responseEntry = null;
  }

  /// Register an unsolicited event handler.
  void registerEvent(ParserResponse event) {
    events.add(event);
  }

  /// Handle a received line. Must be implemented by subclasses.
  void handleRxLine(String line);
}
