import 'package:flutter/material.dart';

import '../db/db_helper.dart';
import '../models/parser_settings.dart';

class ParserSettingsScreen extends StatefulWidget {
  const ParserSettingsScreen({super.key});
  @override
  State<ParserSettingsScreen> createState() => _ParserSettingsScreenState();
}

class _ParserSettingsScreenState extends State<ParserSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _senderController = TextEditingController();
  final _regexController = TextEditingController();
  final _testController = TextEditingController();

  String? _testAmount;
  String? _testReceiver;
  String? _testError;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await DbHelper.instance.getParserSettings();
    _senderController.text = settings.senderMarker;
    _regexController.text = settings.messageRegex;
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _senderController.dispose();
    _regexController.dispose();
    _testController.dispose();
    super.dispose();
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
            'Pattern matched, but it needs at least 2 capture groups (amount, receiver). '
            'Found ${match.groupCount}.');
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
        title: const Text('Update parser settings?'),
        content: const Text(
          'This changes which SMS get auto-tracked from now on. Existing entries are '
          'not affected. If this pattern ever fails to compile on the phone, the app '
          "falls back to the built-in HDFC default so tracking doesn't silently stop.",
        ),
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

  Future<void> _resetDefault() async {
    setState(() {
      _senderController.text = ParserSettings.defaultSenderMarker;
      _regexController.text = ParserSettings.defaultMessageRegex;
    });
    await DbHelper.instance.resetParserSettings();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Reset to the built-in HDFC default.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Parser Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Reset to HDFC default',
            onPressed: _resetDefault,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: ListView(
                  children: [
                    const Text(
                      'Controls which incoming SMS get auto-tracked, and how they\'re '
                      'parsed. The sender check is a simple "contains" match. The pattern '
                      'must have capture group 1 = amount and capture group 2 = receiver '
                      'name — anything else in the message is ignored.',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _senderController,
                      decoration: const InputDecoration(
                        labelText: 'Sender must contain',
                        hintText: 'e.g. HDFCBK',
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
                        hintText: 'Paste a sample SMS body here to try the pattern above',
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
                    const SizedBox(height: 8),
                    const Text(
                      "Note: this preview uses Dart's regex engine; the phone parses with "
                      "Kotlin's engine. They agree on virtually all everyday patterns, but "
                      'if you use advanced regex features, double check on a real message '
                      'afterward via the Unparsed Messages screen.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
