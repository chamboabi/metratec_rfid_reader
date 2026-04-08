/// Abstract base class for inventory scan results.
///
/// Subclasses (e.g., [UhfInventoryResult]) extend this with
/// protocol-specific tag data. The base class provides common
/// fields shared by all inventory result types.
abstract class InventoryResult {
  /// When the tag was detected.
  DateTime timestamp;

  /// How many times this tag has been seen (for deduplication/counting).
  int count = 1;

  /// Creates an inventory result with the given [timestamp] and [count].
  InventoryResult({
    required this.timestamp,
    this.count = 1,
  });

  /// Creates a copy of this result with optionally overridden fields.
  InventoryResult copyWith({
    DateTime? timestamp,
    int? count,
  });

  /// Returns the column headers for a table display of inventory results.
  static List<String> getTableHeaders() => ["Timestamp", "Count"];

  /// Converts this result into a list of string values for table display.
  ///
  /// If [selectedColumns] is provided, only the specified columns
  /// are included in the output.
  List<String> toTableData({List<String>? selectedColumns});

  /// Compares this result to [b] by the given [compareBy] field name.
  ///
  /// Returns a negative value if this < b, zero if equal, positive if this > b.
  /// Supported field names depend on the subclass implementation.
  int compareTo(InventoryResult b, String compareBy);
}
