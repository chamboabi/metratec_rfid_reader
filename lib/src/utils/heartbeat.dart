import 'package:async/async.dart';

/// Heartbeat timer for reader aliveness monitoring.
class Heartbeat {
  RestartableTimer? _hbtTimer;
  Function? _hbtFunction;

  /// Start heartbeat with timeout of [timeoutMs] milliseconds.
  /// On heartbeat received, [onHbt] is called.
  /// On timeout, [onTimeout] is called.
  void start(int timeoutMs, Function onHbt, Function onTimeout) {
    _hbtTimer?.cancel();
    _hbtFunction = onHbt;
    _hbtTimer =
        RestartableTimer(Duration(milliseconds: timeoutMs), () => onTimeout());
  }

  /// Stop heartbeat monitoring.
  void stop() {
    _hbtTimer?.cancel();
    _hbtTimer = null;
    _hbtFunction = null;
  }

  /// Feed the heartbeat timer (reset countdown).
  void feed() {
    _hbtTimer?.reset();
    if (_hbtFunction != null) {
      _hbtFunction!();
    }
  }
}
