/// Base class for inventory results.
abstract class InventoryResult {
  DateTime timestamp;
  int count = 1;

  InventoryResult({
    required this.timestamp,
    this.count = 1,
  });

  InventoryResult copyWith({
    DateTime? timestamp,
    int? count,
  });

  static List<String> getTableHeaders() => ["Timestamp", "Count"];

  List<String> toTableData({List<String>? selectedColumns});

  int compareTo(InventoryResult b, String compareBy);
}
