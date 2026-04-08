/// Memory bank definitions for UHF tags.
enum Membank {
  none,
  epc,
  tid,
  user,
  pc,
  lock,
  kill;

  @override
  String toString() => switch (this) {
        Membank.epc => "EPC",
        Membank.tid => "TID",
        Membank.pc => "PC",
        Membank.user => "User",
        Membank.none => "None",
        Membank.lock => "Lock Pwd",
        Membank.kill => "Kill Pwd",
      };

  String get protocolString => switch (this) {
        Membank.epc => "EPC",
        Membank.tid => "TID",
        Membank.pc => "PC",
        Membank.user => "USR",
        Membank.none => "None",
        Membank.lock => "LCK",
        Membank.kill => "KILL",
      };
}
