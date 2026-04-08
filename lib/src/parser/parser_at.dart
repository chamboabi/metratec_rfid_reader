import 'package:metratec_rfid_reader/src/parser/parser.dart';

/// AT protocol parser implementation.
/// Handles OK/ERROR termination and prefix-based response matching.
class ParserAt extends Parser {
  ParserAt(super.commInterface, super.eol);

  /// Check if the received line matches a registered event.
  bool _handleEvents(String line) {
    for (ParserResponse event in events) {
      if (line.startsWith(event.prefix)) {
        try {
          event.dataCb(line);
        } catch (e) {
          // Don't let event handler errors crash the parser
        }
        return true;
      }
    }
    return false;
  }

  /// Check if the received line terminates a running command.
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

  @override
  void handleRxLine(String line) {
    // First check if the line is a registered event
    if (_handleEvents(line)) {
      return;
    }

    // Check if the line terminates a running command
    if (_handleTermination(line)) {
      return;
    }

    // Check for prefix matches on registered responses
    if (responseEntry == null) {
      return;
    }

    for (ParserResponse rsp in responseEntry!.responses) {
      if (line.startsWith(rsp.prefix)) {
        try {
          rsp.dataCb(line.replaceFirst("${rsp.prefix}: ", ''));
        } catch (e) {
          // Don't let response handler errors crash the parser
        }
      }
    }
  }
}
