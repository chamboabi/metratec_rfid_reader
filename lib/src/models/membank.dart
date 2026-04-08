/// UHF RFID tag memory bank definitions.
///
/// Defines the available memory banks on a Gen2 UHF tag. Each bank
/// serves a different purpose and has different access controls.
///
/// Used with [UhfReaderAt.readTag], [UhfReaderAt.writeTag], and
/// tag security operations.
enum Membank {
  /// No memory bank selected.
  none,

  /// Electronic Product Code memory bank.
  /// Contains the tag's primary identifier (EPC).
  epc,

  /// Transponder ID memory bank.
  /// Contains the factory-programmed unique tag identifier.
  /// Typically read-only.
  tid,

  /// User memory bank.
  /// Available for application-specific data storage.
  /// Size varies by tag model (some tags have no user memory).
  user,

  /// Protocol Control (PC) bits.
  /// Contains tag metadata such as EPC length and numbering system.
  pc,

  /// Lock password memory area.
  /// Contains the 32-bit access password used for lock/unlock operations.
  lock,

  /// Kill password memory area.
  /// Contains the 32-bit kill password used to permanently disable a tag.
  kill;

  /// Returns a human-readable display name for this memory bank.
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

  /// Returns the AT protocol string for this memory bank.
  ///
  /// This is the string used in AT commands (e.g., `"EPC"`, `"TID"`,
  /// `"USR"`, `"PC"`, `"LCK"`, `"KILL"`).
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
