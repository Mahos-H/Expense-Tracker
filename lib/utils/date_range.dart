enum RangePreset { today, week, month, year, all, custom }

class DateRange {
  final DateTime? start;
  final DateTime? end; // exclusive
  final RangePreset preset;

  const DateRange({this.start, this.end, required this.preset});

  /// Uses the device's own clock (DateTime.now()) — no network time source
  /// is involved anywhere in this app.
  static DateRange forPreset(RangePreset preset, {DateTime? now}) {
    final n = now ?? DateTime.now();
    switch (preset) {
      case RangePreset.today:
        final start = DateTime(n.year, n.month, n.day);
        return DateRange(start: start, end: start.add(const Duration(days: 1)), preset: preset);
      case RangePreset.week:
        final startOfDay = DateTime(n.year, n.month, n.day);
        final start = startOfDay.subtract(Duration(days: n.weekday - 1));
        return DateRange(start: start, end: start.add(const Duration(days: 7)), preset: preset);
      case RangePreset.month:
        final start = DateTime(n.year, n.month, 1);
        final end = (n.month == 12) ? DateTime(n.year + 1, 1, 1) : DateTime(n.year, n.month + 1, 1);
        return DateRange(start: start, end: end, preset: preset);
      case RangePreset.year:
        return DateRange(start: DateTime(n.year, 1, 1), end: DateTime(n.year + 1, 1, 1), preset: preset);
      case RangePreset.all:
        return DateRange(start: null, end: null, preset: preset);
      case RangePreset.custom:
        return DateRange(start: null, end: null, preset: preset);
    }
  }
}
