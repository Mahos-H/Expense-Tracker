import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/db_helper.dart';
import '../models/entry.dart';
import '../theme/app_theme.dart';
import '../utils/date_range.dart';

class _ChartPoint {
  final DateTime time;
  final double value;
  _ChartPoint(this.time, this.value);
}

class TrendScreen extends StatefulWidget {
  const TrendScreen({super.key});
  @override
  State<TrendScreen> createState() => _TrendScreenState();
}

class _TrendScreenState extends State<TrendScreen> {
  RangePreset _preset = RangePreset.month;
  DateTime? _customStart;
  DateTime? _customEnd;
  bool _loading = true;
  List<_ChartPoint> _points = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateRange get _currentRange {
    if (_preset == RangePreset.custom) {
      return DateRange(start: _customStart, end: _customEnd, preset: _preset);
    }
    return DateRange.forPreset(_preset);
  }

  /// Builds a cumulative running-total series:
  ///  - `baseline` = sum of every entry dated before the range starts
  ///    (this is what "start at previous expenses" means here — the graph
  ///    begins at whatever the account had already accumulated, not at ₹0).
  ///  - each entry inside the range then nudges the running total up/down.
  ///  - the line is extended flat to the right edge of the range if nothing
  ///    happened right up to the boundary, so short/quiet frames still show
  ///    a visible line instead of a single dot.
  Future<void> _load() async {
    setState(() => _loading = true);
    final all = await DbHelper.instance.getAllEntriesAscending();
    final range = _currentRange;

    double baseline = 0;
    final withinRange = <ExpenseEntry>[];
    for (final e in all) {
      final beforeStart = range.start != null && e.entryDate.isBefore(range.start!);
      if (beforeStart) {
        baseline += e.amount;
        continue;
      }
      final atOrAfterEnd = range.end != null && !e.entryDate.isBefore(range.end!);
      if (atOrAfterEnd) continue;
      withinRange.add(e);
    }

    final points = <_ChartPoint>[];
    double running = baseline;

    if (range.start != null) {
      points.add(_ChartPoint(range.start!, running));
      for (final e in withinRange) {
        running += e.amount;
        points.add(_ChartPoint(e.entryDate, running));
      }
    } else if (withinRange.isNotEmpty) {
      // "All" view has no left boundary — start right at the very first
      // entry (which, chronologically, is usually the anchor itself).
      for (final e in withinRange) {
        running += e.amount;
        points.add(_ChartPoint(e.entryDate, running));
      }
    }

    if (range.end != null) {
      final edge = range.end!.subtract(const Duration(seconds: 1));
      if (points.isEmpty || edge.isAfter(points.last.time)) {
        points.add(_ChartPoint(edge, running));
      }
    }

    if (!mounted) return;
    setState(() {
      _points = points;
      _loading = false;
    });
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: DateTimeRange(
        start: _customStart ?? now.subtract(const Duration(days: 7)),
        end: _customEnd ?? now,
      ),
    );
    if (result != null) {
      setState(() {
        _preset = RangePreset.custom;
        _customStart = DateTime(result.start.year, result.start.month, result.start.day);
        _customEnd =
            DateTime(result.end.year, result.end.month, result.end.day).add(const Duration(days: 1));
      });
      _load();
    }
  }

  String Function(DateTime) get _xLabelFormatter {
    switch (_preset) {
      case RangePreset.today:
        return (d) => DateFormat('HH:mm').format(d);
      case RangePreset.week:
        return (d) => DateFormat('EEE').format(d);
      case RangePreset.month:
      case RangePreset.custom:
        return (d) => DateFormat('d MMM').format(d);
      case RangePreset.year:
      case RangePreset.all:
        return (d) => DateFormat('MMM yy').format(d);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _points.isEmpty ? 0.0 : _points.last.value;
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '\u20B9', decimalDigits: 0);
    final compact = NumberFormat.compactCurrency(locale: 'en_IN', symbol: '\u20B9');

    return Scaffold(
      appBar: AppBar(title: const Text('Trend')),
      body: Column(
        children: [
          _rangeSelector(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Running total at end of range',
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
                Text(
                  currency.format(total),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: total < 0 ? AppTheme.negativeColor : AppTheme.positiveColor,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _points.length < 2
                    ? const Center(child: Text('Not enough data yet for a trend line'))
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: _LineChartPainter(
                            points: _points,
                            lineColor: AppTheme.positiveColor,
                            gridColor: Colors.white10,
                            labelColor: Colors.grey,
                            yFormat: compact,
                            xLabelFormat: _xLabelFormatter,
                          ),
                        ),
                      ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              "The Y-axis is zoomed to this range's actual values, not from \u20B90 — "
              'read the axis labels, not just the shape, when comparing across time frames.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rangeSelector() {
    final options = <RangePreset, String>{
      RangePreset.today: 'Today',
      RangePreset.week: 'Week',
      RangePreset.month: 'Month',
      RangePreset.year: 'Year',
      RangePreset.all: 'All',
    };
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          ...options.entries.map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(e.value),
                selected: _preset == e.key,
                onSelected: (_) {
                  setState(() => _preset = e.key);
                  _load();
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: const Text('Custom'),
              selected: _preset == RangePreset.custom,
              onSelected: (_) => _pickCustomRange(),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<_ChartPoint> points;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;
  final NumberFormat yFormat;
  final String Function(DateTime) xLabelFormat;

  _LineChartPainter({
    required this.points,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
    required this.yFormat,
    required this.xLabelFormat,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const leftPad = 60.0;
    const rightPad = 8.0;
    const topPad = 12.0;
    const bottomPad = 28.0;

    final plotWidth = (size.width - leftPad - rightPad).clamp(1.0, double.infinity);
    final plotHeight = (size.height - topPad - bottomPad).clamp(1.0, double.infinity);

    double minY = points.map((pt) => pt.value).reduce((a, b) => a < b ? a : b);
    double maxY = points.map((pt) => pt.value).reduce((a, b) => a > b ? a : b);

    // The whole point of a "relative" graph: zoom into the actual range of
    // values instead of forcing the axis down to ₹0, where a normal day's
    // fluctuation would be an invisible sliver against a 20-30k baseline.
    if ((maxY - minY).abs() < 1) {
      minY -= 50;
      maxY += 50;
    } else {
      final pad = (maxY - minY) * 0.12;
      minY -= pad;
      maxY += pad;
    }

    final minX = points.first.time.millisecondsSinceEpoch.toDouble();
    final maxX = points.last.time.millisecondsSinceEpoch.toDouble();
    final xSpan = (maxX - minX) == 0 ? 1.0 : (maxX - minX);

    Offset toOffset(_ChartPoint pt) {
      final xFrac = (pt.time.millisecondsSinceEpoch - minX) / xSpan;
      final yFrac = (pt.value - minY) / (maxY - minY);
      return Offset(
        leftPad + xFrac * plotWidth,
        topPad + (1 - yFrac) * plotHeight,
      );
    }

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final textStyle = TextStyle(color: labelColor, fontSize: 11);

    const gridLines = 4;
    for (int i = 0; i <= gridLines; i++) {
      final frac = i / gridLines;
      final y = topPad + frac * plotHeight;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width - rightPad, y), gridPaint);
      final value = maxY - frac * (maxY - minY);
      final tp = TextPainter(
        text: TextSpan(text: yFormat.format(value), style: textStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, (y - tp.height / 2).clamp(0, size.height - tp.height)));
    }

    const xLabelCount = 4;
    for (int i = 0; i <= xLabelCount; i++) {
      final frac = i / xLabelCount;
      final ms = minX + frac * xSpan;
      final dt = DateTime.fromMillisecondsSinceEpoch(ms.round());
      final tp = TextPainter(
        text: TextSpan(text: xLabelFormat(dt), style: textStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      final x = (leftPad + frac * plotWidth - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(x, size.height - bottomPad + 6));
    }

    final path = Path();
    for (int i = 0; i < points.length; i++) {
      final o = toOffset(points[i]);
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }

    final fillPath = Path();
    for (int i = 0; i < points.length; i++) {
      final o = toOffset(points[i]);
      if (i == 0) {
        fillPath.moveTo(o.dx, o.dy);
      } else {
        fillPath.lineTo(o.dx, o.dy);
      }
    }
    fillPath.lineTo(toOffset(points.last).dx, topPad + plotHeight);
    fillPath.lineTo(toOffset(points.first).dx, topPad + plotHeight);
    fillPath.close();
    canvas.drawPath(fillPath, Paint()..color = lineColor.withValues(alpha: 0.12));

    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    if (points.length <= 60) {
      final dotPaint = Paint()..color = lineColor;
      for (final pt in points) {
        canvas.drawCircle(toOffset(pt), 2.5, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}
