import 'package:metratec_rfid_reader/src/models/inventory_result.dart';

/// Represents a single UHF RFID tag detected during an inventory scan.
///
/// Contains the tag's identifying information:
/// - [epc] -- Electronic Product Code (always present)
/// - [tid] -- Transponder ID (present if TID is enabled in inventory settings)
/// - [rssi] -- Received Signal Strength Indicator (present if RSSI is enabled)
class UhfTag {
  /// The Electronic Product Code (primary tag identifier).
  /// This is a hex string (e.g., `"E2801160600002055609E33C"`).
  String epc;

  /// The Transponder ID (factory-programmed unique identifier).
  /// Empty string if TID reporting is disabled in inventory settings.
  String tid;

  /// Received Signal Strength Indicator in dBm.
  /// Zero if RSSI reporting is disabled in inventory settings.
  int rssi;

  /// Creates a UHF tag with the given [epc], [tid], and [rssi].
  UhfTag(this.epc, this.tid, this.rssi);

  /// Creates a deep copy of this tag.
  UhfTag copy() => UhfTag(epc, tid, rssi);

  @override
  String toString() => "{EPC:$epc, TID:$tid, RSSI:$rssi}";
}

/// Result of a UHF inventory scan, combining a [UhfTag] with metadata.
///
/// Extends [InventoryResult] with UHF-specific fields: the detected
/// [tag] and the [lastAntenna] port it was seen on.
///
/// Instances are returned by [UhfReaderAt.inventory],
/// [UhfReaderAt.muxInventory], and via the [UhfReaderAt.cinvStream]
/// during continuous inventory.
class UhfInventoryResult extends InventoryResult {
  /// The detected UHF tag with EPC, TID, and RSSI data.
  UhfTag tag;

  /// The antenna port number (1-based) where this tag was last detected.
  /// Set to 0 if the antenna is not yet known (e.g., during accumulation
  /// before a "ROUND FINISHED" message).
  int lastAntenna;

  /// Creates a UHF inventory result for the given [tag] and [lastAntenna].
  UhfInventoryResult({
    required this.tag,
    required this.lastAntenna,
    required super.timestamp,
    super.count = 1,
  });

  @override
  UhfInventoryResult copyWith({
    UhfTag? tag,
    DateTime? timestamp,
    int? lastAntenna,
    int? count,
  }) {
    return UhfInventoryResult(
      tag: tag ?? this.tag.copy(),
      timestamp: timestamp ?? this.timestamp,
      lastAntenna: lastAntenna ?? this.lastAntenna,
      count: count ?? this.count,
    );
  }

  /// Converts this result to a list of strings for table display.
  ///
  /// Returns: `[epc, tid, rssi, timestamp, antenna, count]`.
  @override
  List<String> toTableData({List<String>? selectedColumns}) => [
        tag.epc,
        tag.tid,
        tag.rssi.toString(),
        timestamp.toIso8601String(),
        lastAntenna.toString(),
        count.toString(),
      ];

  /// Compares this result to [b] for sorting.
  ///
  /// Supported [compareBy] values:
  /// - `"EPC"` -- alphabetical comparison by EPC string.
  /// - `"RSSI"` -- numerical comparison by signal strength.
  /// - `"Timestamp"` -- chronological comparison.
  @override
  int compareTo(InventoryResult b, String compareBy) {
    if (b is! UhfInventoryResult) return 0;
    return switch (compareBy) {
      "EPC" => tag.epc.compareTo(b.tag.epc),
      "RSSI" => tag.rssi.compareTo(b.tag.rssi),
      "Timestamp" => timestamp.compareTo(b.timestamp),
      _ => 0,
    };
  }

  @override
  String toString() =>
      "{tag: $tag, antenna: $lastAntenna, count: $count}";
}
