import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class ImportSmsScreen extends StatefulWidget {
  const ImportSmsScreen({super.key});
  @override
  State<ImportSmsScreen> createState() => _ImportSmsScreenState();
}

class _ImportSmsScreenState extends State<ImportSmsScreen> {
  static const _channel = MethodChannel('com.expensetracker.hdfc/permissions');

  bool? _hasReadSmsPermission;
  // Prefilled with the range that's actually needed right now; adjust freely
  // for a different recovery window later.
  DateTime _start = DateTime(2026, 8, 7);
  DateTime _end = DateTime(2026, 9, 29);

  bool _running = false;
  Map<String, int>? _lastResult;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('hasReadSmsPermission') ?? false;
      if (mounted) setState(() => _hasReadSmsPermission = granted);
    } on PlatformException {
      if (mounted) setState(() => _hasReadSmsPermission = false);
    }
  }

  Future<void> _requestPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('requestReadSmsPermission') ?? false;
      if (mounted) setState(() => _hasReadSmsPermission = granted);
    } on PlatformException {
      // ignore
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final initial = isStart ? _start : _end;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2015),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _start = DateTime(picked.year, picked.month, picked.day);
      } else {
        _end = DateTime(picked.year, picked.month, picked.day);
      }
    });
  }

  Future<void> _runScan() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Scan SMS inbox?'),
        content: Text(
          'Scans every inbox SMS from ${DateFormat('d MMM yyyy').format(_start)} to '
          '${DateFormat('d MMM yyyy').format(_end)} for anything containing "HDFC", '
          'regardless of sender, and tries to parse each one with your current '
          'Parser Settings. Anything already in your entries is skipped '
          "automatically — running this again over the same range won't create "
          'duplicates.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Scan')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _running = true;
      _lastResult = null;
    });

    try {
      // End date is treated as inclusive of that whole day.
      final endExclusive = DateTime(_end.year, _end.month, _end.day).add(const Duration(days: 1));
      final result = await _channel.invokeMethod<Map>('scanSmsInboxForHdfc', {
        'start': _start.millisecondsSinceEpoch,
        'end': endExclusive.subtract(const Duration(milliseconds: 1)).millisecondsSinceEpoch,
      });
      if (!mounted) return;
      setState(() {
        _lastResult = result?.map((k, v) => MapEntry(k.toString(), v as int));
        _running = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scan failed: ${e.message ?? e.code}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import from SMS')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            const Text(
              'One-time recovery tool: scans your phone\'s SMS inbox directly (not '
              'just new messages) for anything containing "HDFC" in the date range '
              "below, and imports what it can parse. Needs a separate permission "
              "from normal live tracking.",
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            if (_hasReadSmsPermission == false)
              Card(
                color: Colors.orange.shade900,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'SMS read permission not granted yet.',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      TextButton(
                        onPressed: _requestPermission,
                        child: const Text('Grant', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('From'),
              subtitle: Text(DateFormat('d MMM yyyy').format(_start)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () => _pickDate(isStart: true),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('To'),
              subtitle: Text(DateFormat('d MMM yyyy').format(_end)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () => _pickDate(isStart: false),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: (_hasReadSmsPermission == true && !_running) ? _runScan : null,
              child: _running
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Scan & Import'),
            ),
            if (_lastResult != null) ...[
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Result', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text('Messages containing "HDFC": ${_lastResult!['scanned'] ?? 0}'),
                      Text('Imported as entries: ${_lastResult!['inserted'] ?? 0}'),
                      Text('Logged to Unparsed Messages: ${_lastResult!['unparsed'] ?? 0}'),
                      const SizedBox(height: 8),
                      const Text(
                        'Check Unparsed Messages for anything that didn\'t import '
                        'automatically — those can be added manually.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}