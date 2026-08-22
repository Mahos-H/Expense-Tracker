class ExpenseEntry {
  final int? id;
  final double amount; // positive = debit (spent), negative = credit (received)
  final String receiver;
  final DateTime entryDate;
  final String source; // 'sms' | 'manual' | 'system'
  final String? rawSmsBody;
  final DateTime createdAt;
  final bool isPreviousExpense;

  ExpenseEntry({
    this.id,
    required this.amount,
    required this.receiver,
    required this.entryDate,
    required this.source,
    this.rawSmsBody,
    required this.createdAt,
    this.isPreviousExpense = false,
  });

  factory ExpenseEntry.fromMap(Map<String, dynamic> m) => ExpenseEntry(
        id: m['id'] as int?,
        amount: (m['amount'] as num).toDouble(),
        receiver: m['receiver'] as String,
        entryDate: DateTime.parse(m['entry_date'] as String),
        source: m['source'] as String,
        rawSmsBody: m['raw_sms_body'] as String?,
        createdAt: DateTime.parse(m['created_at'] as String),
        isPreviousExpense: (m['is_previous_expense'] as int) == 1,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'amount': amount,
        'receiver': receiver,
        'entry_date': _iso(entryDate),
        'source': source,
        'raw_sms_body': rawSmsBody,
        'created_at': _iso(createdAt),
        'is_previous_expense': isPreviousExpense ? 1 : 0,
      };

  static String _iso(DateTime d) => d.toIso8601String().split('.').first;
}
