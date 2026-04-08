import 'package:async/async.dart';

/// Heartbeat timer for monitoring RFID reader connection aliveness.
///
/// The heartbeat works as a watchdog timer: the reader periodically
/// sends `+HBT` unsolicited responses, and [feed] must be called
/// each time one is received to reset the countdown. If [feed] is
/// not called within the timeout period, the [onTimeout] callback
/// fires, indicating the reader may have disconnected.
///
/// Uses [RestartableTimer] from the `async` package for efficient
/// timer management without creating new timer objects on each feed.
///
/// Example:
/// ```dart
/// final hbt = Heartbeat();
/// hbt.start(
///   7000,                       // timeout in milliseconds
///   () => print('Heartbeat OK'),  // called on each feed
///   () => print('Connection lost!'), // called on timeout
/// );
///
/// // Call hbt.feed() each time a +HBT is received from the reader.
/// hbt.feed();
///
/// // Stop monitoring when done.
/// hbt.stop();
/// ```
class Heartbeat {
  /// The underlying restartable timer. Null when not running.
  RestartableTimer? _hbtTimer;

  /// The callback invoked on each [feed] (heartbeat received).
  Function? _hbtFunction;

  /// Starts heartbeat monitoring with the given [timeoutMs].
  ///
  /// - [timeoutMs] -- milliseconds to wait for a heartbeat before timing out.
  /// - [onHbt] -- called each time [feed] is invoked (heartbeat received).
  /// - [onTimeout] -- called if no [feed] occurs within [timeoutMs].
  ///
  /// If a heartbeat is already running, it is stopped first.
  void start(int timeoutMs, Function onHbt, Function onTimeout) {
    _hbtTimer?.cancel();
    _hbtFunction = onHbt;
    _hbtTimer =
        RestartableTimer(Duration(milliseconds: timeoutMs), () => onTimeout());
  }

  /// Stops heartbeat monitoring and cancels the timer.
  ///
  /// Safe to call even if no heartbeat is running.
  void stop() {
    _hbtTimer?.cancel();
    _hbtTimer = null;
    _hbtFunction = null;
  }

  /// Feeds the heartbeat timer, resetting the timeout countdown.
  ///
  /// This should be called each time a `+HBT` unsolicited response
  /// is received from the reader. Resets the timer and invokes the
  /// [onHbt] callback to signal that the connection is alive.
  void feed() {
    _hbtTimer?.reset();
    if (_hbtFunction != null) {
      _hbtFunction!();
    }
  }
}
