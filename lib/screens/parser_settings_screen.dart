import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/db_helper.dart';
import '../models/diagnostics_info.dart';

class ParserSettingsScreen extends StatefulWidget {
  const ParserSettingsScreen({super.key});
  @override
  State<ParserSettingsScreen> createState() => _ParserSettingsScreenState();
}

class _ParserSettingsScreenState extends State<ParserSettingsScreen> {
  static const _channel = MethodChannel('com.expensetracker.hdfc/permissions');

  final _formKey = GlobalKey<FormState>();
  final _senderController = TextEditingController();
  final _regexController = TextEditingController();
  final _testController = TextEditingController();

  String? _testAmount;
  String? _testReceiver;
  String? _testError;
  bool _loading = true;
  bool _exporting = false;
  DiagnosticsInfo? _diagnostics;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await DbHelper.instance.getParserSettings();
    final diagnostics = await DbHelper.instance.getDiagnostics();
    _senderController.text = settings.senderMarker;
    _regexController.text = settings.messageRegex;
    if (mounted) {
      setState(() {
        _diagnostics = diagnostics;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _senderController.dispose();
    _regexController.dispose();
    _testController.dispose();
    super.dispose();
  }

  Future<void> _exportNow() async {
    setState(() => _exporting = true);
    try {
      final fileName = await _channel.invokeMethod<String>('exportDatabaseNow');
      if (!mounted) return;
      setState(() => _exporting = false);
      if (fileName != null) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Exported'),
            content: Text(
              'Saved to your Downloads folder as:\n\n$fileName\n\n'
              'This is a plain file now, outside the app\'s private storage — '
              'copy it to your laptop however\'s convenient (USB file transfer, '
              'adb pull, cloud sync) and it\'ll open directly in DB Browser for '
              'SQLite or any sqlite3 tool.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export failed — check device storage/logs.')),
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: ${e.message ?? e.code}')),
      );
    }
  }

  void _runTest() {
    setState(() {
      _testAmount = null;
      _testReceiver = null;
      _testError = null;
    });
    try {
      final regex = RegExp(_regexController.text.trim(), caseSensitive: false);
      final match = regex.firstMatch(_testController.text);
      if (match == null) {
        setState(() => _testError = 'No match against the sample message.');
        return;
      }
      if (match.groupCount < 2) {
        setState(() => _testError =
            'Needs at least 2 capture groups (amount, receiver). Found ${match.groupCount}.');
        return;
      }
      setState(() {
        _testAmount = match.group(1);
        _testReceiver = match.group(2)?.trim();
      });
    } catch (e) {
      setState(() => _testError = 'Invalid regex: $e');
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    try {
      RegExp(_regexController.text.trim());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Regex does not compile: $e')));
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save parser settings?'),
        content: const Text('This changes which SMS get auto-tracked from now on.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (confirmed != true) return;

    await DbHelper.instance.updateParserSettings(
      _senderController.text.trim(),
      _regexController.text.trim(),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Parser settings saved.')));
    }
  }

  Widget _diagnosticsCard() {
    final lastBroadcast = _diagnostics?.lastBroadcastAt;
    final text = lastBroadcast == null
        ? 'never'
        : DateFormat('dd MMM yyyy, hh:mm:ss a').format(lastBroadcast);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text('Last SMS seen: $text')),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Refresh',
              onPressed: _load,
            ),
          ],
        ),
      ),
    );
  }

  Widget _exportCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Save a copy of the whole database to Downloads right now.',
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _exporting ? null : _exportNow,
              child: _exporting
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Export now'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Parser Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: ListView(
                  children: [
                    _diagnosticsCard(),
                    const SizedBox(height: 8),
                    _exportCard(),
                    const SizedBox(height: 16),
                    const Text(
                      'Capture group 1 must be the amount, group 2 the receiver name.',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _senderController,
                      decoration: const InputDecoration(
                        labelText: 'Sender must contain',
                        hintText: 'e.g. HDFC',
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _regexController,
                      minLines: 3,
                      maxLines: 6,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: const InputDecoration(labelText: 'Message pattern (regex)'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 8),
                    const Text('Test against a sample message',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _testController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Paste a sample SMS body here',
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: _runTest, child: const Text('Run test')),
                    if (_testError != null) ...[
                      const SizedBox(height: 8),
                      Text(_testError!, style: const TextStyle(color: Colors.redAccent)),
                    ],
                    if (_testAmount != null) ...[
                      const SizedBox(height: 8),
                      Text('Amount matched: $_testAmount',
                          style: const TextStyle(color: Colors.greenAccent)),
                      Text('Receiver matched: $_testReceiver',
                          style: const TextStyle(color: Colors.greenAccent)),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(onPressed: _save, child: const Text('Save parser settings')),
                  ],
                ),
              ),
            ),
    );
  }
}