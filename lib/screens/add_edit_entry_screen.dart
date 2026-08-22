import 'package:flutter/material.dart';

import '../db/db_helper.dart';
import '../models/entry.dart';

class AddEditEntryScreen extends StatefulWidget {
  final ExpenseEntry? existing;
  const AddEditEntryScreen({super.key, this.existing});

  @override
  State<AddEditEntryScreen> createState() => _AddEditEntryScreenState();
}

class _AddEditEntryScreenState extends State<AddEditEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _amountController;
  late TextEditingController _receiverController;
  late DateTime _selectedDateTime;
  bool _isDebit = true;

  bool get _isEditing => widget.existing != null;
  bool get _isAnchor => widget.existing?.isPreviousExpense ?? false;
  // The SMS timestamp is ground truth for when the transaction happened —
  // everything else about an SMS-derived entry stays editable, but the
  // date/time itself is locked so it can never drift from what the bank
  // actually sent.
  bool get _isDateLocked => widget.existing?.source == 'sms';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _amountController = TextEditingController(
      text: e != null ? e.amount.abs().toStringAsFixed(2) : '',
    );
    _receiverController = TextEditingController(text: e?.receiver ?? '');
    _selectedDateTime = e?.entryDate ?? DateTime.now();
    _isDebit = e == null ? true : e.amount >= 0;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _receiverController.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    if (_isDateLocked) return;
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDateTime,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_selectedDateTime),
    );
    if (time == null) return;
    setState(() {
      _selectedDateTime =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<bool> _confirm(String title, String content, {bool danger = false}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              danger ? 'Delete' : 'Yes, save',
              style: danger ? const TextStyle(color: Colors.redAccent) : null,
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (_isEditing) {
      final confirmed = await _confirm(
        'Save changes?',
        'Are you sure you want to edit this entry? This updates the amount, '
        'name, and date shown above.',
      );
      if (!confirmed) return;
    }

    final rawAmount = double.parse(_amountController.text.trim());
    final signedAmount = _isDebit ? rawAmount : -rawAmount;
    final receiver = _receiverController.text.trim();
    final now = DateTime.now();

    if (_isEditing) {
      final updated = ExpenseEntry(
        id: widget.existing!.id,
        amount: signedAmount,
        receiver: receiver,
        // Locked entries keep their original SMS timestamp no matter what
        // was in the (disabled) date field.
        entryDate: _isDateLocked ? widget.existing!.entryDate : _selectedDateTime,
        source: widget.existing!.source,
        rawSmsBody: widget.existing!.rawSmsBody,
        createdAt: widget.existing!.createdAt,
        isPreviousExpense: widget.existing!.isPreviousExpense,
      );
      await DbHelper.instance.updateEntry(updated);
    } else {
      final entry = ExpenseEntry(
        amount: signedAmount,
        receiver: receiver,
        entryDate: _selectedDateTime,
        source: 'manual',
        createdAt: now,
      );
      await DbHelper.instance.insertManualEntry(entry);
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    if (widget.existing?.id == null) return;
    final confirmed = await _confirm(
      'Delete this entry?',
      'Are you sure you want to delete "${_receiverController.text.trim()}"? '
      'This cannot be undone.',
      danger: true,
    );
    if (!confirmed) return;
    await DbHelper.instance.deleteEntry(widget.existing!.id!);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit Entry' : 'Add Manual Entry')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              if (_isAnchor)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    'This is the anchor entry representing your balance before tracking '
                    'started (plus anything folded in from pruned old entries). Every '
                    "field here is editable, but this entry can't be deleted — the app "
                    'relies on it always existing to keep your all-time total correct.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Debit (spent)')),
                  ButtonSegment(value: false, label: Text('Credit (received)')),
                ],
                selected: {_isDebit},
                onSelectionChanged: (s) => setState(() => _isDebit = s.first),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount', prefixText: '\u20B9 '),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Enter an amount';
                  final val = double.tryParse(v.trim());
                  if (val == null || val < 0) return 'Enter a valid non-negative amount';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _receiverController,
                decoration: const InputDecoration(labelText: 'Receiver / Label'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date & time'),
                subtitle: Text(_selectedDateTime.toString()),
                trailing: Icon(
                  _isDateLocked ? Icons.lock_outline : Icons.edit_calendar_outlined,
                  color: _isDateLocked ? Colors.grey : null,
                ),
                onTap: _isDateLocked ? null : _pickDateTime,
              ),
              if (_isDateLocked)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    "Date & time comes directly from the SMS and can't be changed — "
                    'everything else on this entry can.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
              if (_isEditing && widget.existing?.source == 'sms') ...[
                const SizedBox(height: 8),
                const Text(
                  'Originally created automatically from an SMS. Editing the amount or '
                  'name here only changes what you see in the app — it does not affect '
                  'the SMS itself.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(onPressed: _save, child: const Text('Save')),
              if (_isEditing && !_isAnchor) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  label: const Text('Delete entry', style: TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
