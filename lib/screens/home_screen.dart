import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/db_helper.dart';
import '../models/entry.dart';
import '../theme/app_theme.dart';
import '../utils/date_range.dart';
import 'add_edit_entry_screen.dart';
import 'failed_parses_screen.dart';
import 'parser_settings_screen.dart';
import 'rename_rules_screen.dart';
import 'trend_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.expensetracker.hdfc/permissions');

  RangePreset _preset = RangePreset.month; // default: monthly, per device clock
  DateTime? _customStart;
  DateTime? _customEnd;

  bool? _hasSmsPermission;
  List<ExpenseEntry> _entries = [];
  double _total = 0.0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The receiver may have written new entries while the app was
    // backgrounded/closed — reload whenever the app comes back to front.
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
      _refresh();
    }
  }

  Future<void> _checkPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('hasSmsPermission') ?? false;
      if (mounted) setState(() => _hasSmsPermission = granted);
    } on PlatformException {
      if (mounted) setState(() => _hasSmsPermission = false);
    }
  }

  Future<void> _requestPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('requestSmsPermission') ?? false;
      if (mounted) setState(() => _hasSmsPermission = granted);
    } on PlatformException {
      // ignore
    }
  }

  DateRange get _currentRange {
    if (_preset == RangePreset.custom) {
      return DateRange(start: _customStart, end: _customEnd, preset: _preset);
    }
    return DateRange.forPreset(_preset);
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final range = _currentRange;
    final entries = await DbHelper.instance.getEntries(start: range.start, end: range.end);
    final total = entries.fold<double>(0.0, (s, e) => s + e.amount);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _total = total;
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
      _refresh();
    }
  }

  Future<void> _openAddEntry() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddEditEntryScreen()),
    );
    if (result == true) _refresh();
  }

  Future<void> _openEditEntry(ExpenseEntry entry) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AddEditEntryScreen(existing: entry)),
    );
    if (result == true) _refresh();
  }

  Future<void> _deleteEntry(ExpenseEntry entry) async {
    if (entry.id == null || entry.isPreviousExpense) return;
    await DbHelper.instance.deleteEntry(entry.id!);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '\u20B9', decimalDigits: 2);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expense Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.show_chart),
            tooltip: 'Trend',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const TrendScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.rule),
            tooltip: 'Parser settings',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ParserSettingsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Rename rules',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const RenameRulesScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.report_gmailerrorred_outlined),
            tooltip: 'Unparsed messages',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const FailedParsesScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddEntry,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (_hasSmsPermission == false) _permissionBanner(),
          _rangeSelector(),
          _totalCard(currency),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? const Center(child: Text('No entries in this range'))
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: ListView.builder(
                          itemCount: _entries.length,
                          itemBuilder: (context, i) => _entryTile(_entries[i], currency),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _permissionBanner() {
    return Container(
      width: double.infinity,
      color: Colors.orange.shade900,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'SMS permission not granted. New HDFC debit SMS will not be tracked automatically.',
              style: TextStyle(color: Colors.white),
            ),
          ),
          TextButton(
            onPressed: _requestPermission,
            child: const Text('Grant', style: TextStyle(color: Colors.white)),
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
                  _refresh();
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

  Widget _totalCard(NumberFormat currency) {
    final isNegative = _total < 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Total (this range)', style: TextStyle(fontSize: 14, color: Colors.grey)),
            Text(
              currency.format(_total),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: isNegative ? AppTheme.negativeColor : AppTheme.positiveColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(ExpenseEntry entry, NumberFormat currency) {
    final dateStr = DateFormat('dd MMM yyyy, hh:mm a').format(entry.entryDate);
    final isNegative = entry.amount < 0;
    final sourceLabel = entry.source == 'sms'
        ? 'Auto (SMS)'
        : entry.source == 'manual'
            ? 'Manual'
            : 'Anchor';

    final tile = Card(
      child: ListTile(
        onTap: () => _openEditEntry(entry),
        title: Text(entry.receiver, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('$dateStr  \u2022  $sourceLabel'),
        trailing: Text(
          currency.format(entry.amount),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isNegative ? AppTheme.negativeColor : AppTheme.positiveColor,
          ),
        ),
      ),
    );

    if (entry.isPreviousExpense) return tile;

    return Dismissible(
      key: ValueKey(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Colors.red.shade900,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Delete entry?'),
                content: Text('Delete "${entry.receiver}" (${currency.format(entry.amount)})?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => _deleteEntry(entry),
      child: tile,
    );
  }
}
