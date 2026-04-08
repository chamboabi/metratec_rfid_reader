import 'package:metratec_rfid_reader/src/models/inventory_result.dart';

/// Represents a single UHF RFID tag.
class UhfTag {
  String epc;
  String tid;
  int rssi;

  UhfTag(this.epc, this.tid, this.rssi);

  UhfTag copy() => UhfTag(epc, tid, rssi);

  @override
  String toString() => "{EPC:$epc, TID:$tid, RSSI:$rssi}";
}

/// Result of a UHF inventory scan.
class UhfInventoryResult extends InventoryResult {
  UhfTag tag;
  int lastAntenna;

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

  @override
  List<String> toTableData({List<String>? selectedColumns}) => [
        tag.epc,
        tag.tid,
        tag.rssi.toString(),
        timestamp.toIso8601String(),
        lastAntenna.toString(),
        count.toString(),
      ];

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
