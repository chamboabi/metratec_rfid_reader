import 'dart:async';
import 'dart:typed_data';

import 'package:metratec_rfid_reader/metratec_rfid.dart';

/// In-memory [CommInterface] that answers AT commands from a script.
///
/// Every command written to it (without the trailing `\r`) is recorded in
/// [sent] and answered with the lines in [replies] for that command, each
/// terminated with `\r\n`. Commands without a scripted reply get `ERROR`.
/// [emit] pushes unsolicited lines (e.g. `+CMINV` events) at any time.
class FakeComm implements CommInterface {
  FakeComm(this.replies);

  final Map<String, List<String>> replies;
  final List<String> sent = [];
  final StreamController<Uint8List> _rx = StreamController<Uint8List>();
  bool _connected = false;

  @override
  Stream<Uint8List> get rxStream => _rx.stream;

  @override
  set onSocketException(void Function(Object, StackTrace) onSocketException) {}

  @override
  Future<bool> connect({void Function(Object?, StackTrace)? onError}) async {
    _connected = true;
    return true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<void> flush() async {}

  @override
  bool isConnected() => _connected;

  @override
  void setWriteTimeout(int writeTimeout) {}

  @override
  bool write(Uint8List bytes) {
    final cmd = String.fromCharCodes(bytes).trimRight();
    sent.add(cmd);
    final lines = replies[cmd] ?? const ['ERROR'];
    scheduleMicrotask(() => emit(lines));
    return true;
  }

  /// Delivers [lines] to the reader as if the device had sent them.
  void emit(List<String> lines) {
    if (_rx.isClosed) return;
    _rx.add(Uint8List.fromList(lines.map((l) => '$l\r\n').join().codeUnits));
  }

  Future<void> close() => _rx.close();
}
