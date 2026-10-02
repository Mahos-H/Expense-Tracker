import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/db_helper.dart';
import '../models/entry.dart';
import '../theme/app_theme.dart';
import '../utils/date_range.dart';
import 'add_edit_entry_screen.dart';
import 'failed_parses_screen.dart';
import 'import_sms_screen.dart';
import 'parser_settings_screen.dart';
import 'rename_rules_screen.dart';
import 'trend_screen.dart';

// Build with `--dart-define=ENABLE_SMS_IMPORTER=true` to show the "Import
// from SMS" icon. Off by default -- normal day-to-day builds never expose
// it. Note this only controls whether the icon/screen is reachable; the
// READ_SMS permission itself is excluded from the APK entirely only when
// building the "standard" Gradle flavor (see build.gradle.kts notes).
const bool kEnableSmsImporter =
    bool.fromEnvironment('ENABLE_SMS_IMPORTER', defaultValue: false);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.expensetracker.hdfc/permissions');

  RangePreset _preset = RangePreset.month;
  DateTime? _customStart;
  DateTime? _customEnd;

  bool? _hasSmsPermission;
  List<ExpenseEntry> _entries = [];
  bool _loading = true;

  bool _isSearching = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
    _refresh();
    _runBackupCheck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
      _refresh();
      _runBackupCheck();
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

  /// If the in-app request comes back denied and this isn't the first time
  /// asking, Android has permanently blocked its own dialog from showing
  /// again -- the native side detects that and opens system Settings
  /// instead, where the permission can still be flipped manually. Either
  /// way, re-check afterward so the banner reflects the real state.
  Future<void> _requestPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('requestSmsPermission') ?? false;
      if (mounted) setState(() => _hasSmsPermission = granted);
      if (!granted) {
        // Re-check shortly after, in case Settings was opened and the
        // person flips it there instead of through a dialog.
        await Future.delayed(const Duration(milliseconds: 500));
        await _checkPermission();
      }
    } on PlatformException {
      // ignore
    }
  }

  Future<void> _runBackupCheck() async {
    try {
      await _channel.invokeMethod('runDailyBackupCheck');
    } on PlatformException {
      // ignore -- non-critical, will just retry next time the app opens
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
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  // ---------------- Search ----------------

  void _toggleSearch() {
    setState(() {
      if (_isSearching) {
        _isSearching = false;
        _searchController.clear();
        _searchQuery = '';
      } else {
        _isSearching = true;
      }
    });
  }

  bool _matchesFrontPortion(String receiver, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    for (final word in _wordsOf(receiver)) {
      if (word.toLowerCase().startsWith(q)) return true;
    }
    return false;
  }

  List<String> _wordsOf(String text) {
    final words = <String>[];
    for (final chunk in text.split(RegExp(r'\s+'))) {
      if (chunk.isEmpty) continue;
      words.add(chunk);
      words.addAll(_splitCamelCase(chunk));
    }
    return words;
  }

  List<String> _splitCamelCase(String chunk) {
    bool isLower(String c) => c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122;
    bool isUpper(String c) => c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90;

    final parts = <String>[];
    var start = 0;
    for (var i = 1; i < chunk.length; i++) {
      if (isLower(chunk[i - 1]) && isUpper(chunk[i])) {
        parts.add(chunk.substring(start, i));
        start = i;
      }
    }
    if (start > 0) parts.add(chunk.substring(start));
    return parts;
  }

  List<ExpenseEntry> get _visibleEntries {
    if (_searchQuery.trim().isEmpty) return _entries;
    return _entries.where((e) => _matchesFrontPortion(e.receiver, _searchQuery)).toList();
  }

  // ---------------- Date range ----------------

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5, now.month, now.day),
      initialDateRange: DateTimeRange(
        start: _customStart ?? now.subtract(const Duration(days: 7)),
        end: _customEnd != null ? _customEnd!.subtract(const Duration(days: 1)) : now,
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
    final visible = _visibleEntries;
    final total = visible.fold<double>(0.0, (s, e) => s + e.amount);

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search receiver name...',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 16),
                onChanged: (v) => setState(() => _searchQuery = v),
              )
            : const Text('Expense Tracker'),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            tooltip: _isSearching ? 'Close search' : 'Search',
            onPressed: _toggleSearch,
          ),
          if (!_isSearching) ...[
            if (kEnableSmsImporter)
              IconButton(
                icon: const Icon(Icons.sms_outlined),
                tooltip: 'Import from SMS',
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const ImportSmsScreen())),
              ),
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
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddEntry,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (_hasSmsPermission == false) _permissionBanner(),
          if (!_isSearching) _rangeSelector(),
          _totalCard(currency, total),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                    ? Center(
                        child: Text(
                          _searchQuery.trim().isEmpty
                              ? 'No entries in this range'
                              : 'No matches for "$_searchQuery"',
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, i) => _entryTile(visible[i], currency),
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

  Widget _totalCard(NumberFormat currency, double total) {
    final isNegative = total < 0;
    final label = _searchQuery.trim().isEmpty ? 'Total (this range)' : 'Total (matching search)';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 14, color: Colors.grey)),
            Text(
              currency.format(total),
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
      child: InkWell(
        onTap: () => _openEditEntry(entry),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.receiver,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$dateStr  \u2022  $sourceLabel',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                currency.format(entry.amount),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isNegative ? AppTheme.negativeColor : AppTheme.positiveColor,
                ),
              ),
            ],
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