import 'package:flutter/material.dart';

import '../db/db_helper.dart';
import '../models/rename_rule.dart';

class RenameRulesScreen extends StatefulWidget {
  const RenameRulesScreen({super.key});
  @override
  State<RenameRulesScreen> createState() => _RenameRulesScreenState();
}

class _RenameRulesScreenState extends State<RenameRulesScreen> {
  List<RenameRule> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rules = await DbHelper.instance.getRenameRules();
    if (!mounted) return;
    setState(() {
      _rules = rules;
      _loading = false;
    });
  }

  Future<void> _addRule() async {
    final fromController = TextEditingController();
    final toController = TextEditingController();
    bool applyToExisting = true;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New rename rule'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: fromController,
                decoration: const InputDecoration(
                  labelText: 'Exact SMS receiver name',
                  hintText: 'e.g. BOTTLE LAB TECHNOLOGIES P',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: toController,
                decoration: const InputDecoration(labelText: 'Rename to', hintText: 'e.g. Lunch'),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: applyToExisting,
                title: const Text('Apply to existing matching entries'),
                onChanged: (v) => setLocal(() => applyToExisting = v ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (result == true &&
        fromController.text.trim().isNotEmpty &&
        toController.text.trim().isNotEmpty) {
      await DbHelper.instance.addRenameRule(
        fromController.text.trim(),
        toController.text.trim(),
        applyToExisting: applyToExisting,
      );
      _load();
    }
  }

  Future<void> _deleteRule(RenameRule rule) async {
    await DbHelper.instance.deleteRenameRule(rule.id!);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rename Rules')),
      floatingActionButton: FloatingActionButton(onPressed: _addRule, child: const Icon(Icons.add)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rules.isEmpty
              ? const Center(child: Text('No rename rules yet'))
              : ListView.builder(
                  itemCount: _rules.length,
                  itemBuilder: (context, i) {
                    final r = _rules[i];
                    return Card(
                      child: ListTile(
                        title: Text('${r.fromName}  \u2192  ${r.toName}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteRule(r),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
