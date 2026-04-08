import 'package:metratec_rfid_reader/src/parser/parser.dart';

/// AT protocol parser for Metratec RFID readers.
///
/// This concrete [Parser] implementation handles the Metratec AT command
/// protocol. Each received line is processed in the following order:
///
/// 1. **Unsolicited events** -- checked first, since events like `+HBT`
///    (heartbeat) and `+CINV` (continuous inventory) can arrive at any
///    time, even during a command/response cycle.
/// 2. **Command termination** -- `"OK"` completes the running command
///    with [CmdExitCode.ok]; `"ERROR"` completes it with [CmdExitCode.error].
/// 3. **Prefix-matched responses** -- lines matching a registered response
///    handler's prefix have the prefix and separator (`"PREFIX: "`) stripped
///    before being passed to the handler's callback.
///
/// Lines that don't match any of the above are silently discarded.
class ParserAt extends Parser {
  /// Creates an AT parser that communicates over the given [commInterface]
  /// and appends [eol] (typically `"\r"`) to each outgoing command.
  ParserAt(super.commInterface, super.eol);

  /// Checks if the received [line] matches a registered unsolicited event.
  ///
  /// Iterates through all registered event handlers and invokes the
  /// first one whose prefix matches. Returns `true` if a match was found.
  /// Handler errors are caught to prevent crashing the parser.
  bool _handleEvents(String line) {
    for (ParserResponse event in events) {
      if (line.startsWith(event.prefix)) {
        try {
          event.dataCb(line);
        } catch (e) {
          // Don't let event handler errors crash the parser.
        }
        return true;
      }
    }
    return false;
  }

  /// Checks if the received [line] is a command termination marker.
  ///
  /// - `"OK"` terminates the running command with [CmdExitCode.ok].
  /// - `"ERROR"` terminates it with [CmdExitCode.error].
  ///
  /// Returns `true` if the line was a termination marker.
  bool _handleTermination(String line) {
    if (line == "OK") {
      finishCommand(CmdExitCode.ok);
      return true;
    } else if (line == "ERROR") {
      finishCommand(CmdExitCode.error);
      return true;
    }
    return false;
  }

  /// Processes a single received line according to the AT protocol.
  ///
  /// Lines are checked in order: events -> termination -> prefix responses.
  /// If a running command has response handlers, matching lines have their
  /// prefix and `": "` separator stripped before the data is delivered
  /// to the handler callback.
  @override
  void handleRxLine(String line) {
    // First check if the line is a registered unsolicited event.
    if (_handleEvents(line)) {
      return;
    }

    // Check if the line terminates a running command (OK or ERROR).
    if (_handleTermination(line)) {
      return;
    }

    // No running command -- nothing to match against.
    if (responseEntry == null) {
      return;
    }

    // Check for prefix matches on the running command's response handlers.
    for (ParserResponse rsp in responseEntry!.responses) {
      if (line.startsWith(rsp.prefix)) {
        try {
          // Strip the prefix and separator before delivering to the callback.
          rsp.dataCb(line.replaceFirst("${rsp.prefix}: ", ''));
        } catch (e) {
          // Don't let response handler errors crash the parser.
        }
      }
    }
  }
}
