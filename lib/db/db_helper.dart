import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/diagnostics_info.dart';
import '../models/entry.dart';
import '../models/failed_parse.dart';
import '../models/parser_settings.dart';
import '../models/rename_rule.dart';

class DbHelper {
  DbHelper._internal();
  static final DbHelper instance = DbHelper._internal();

  static const String dbName = 'expense_tracker.db';
  static const int dbVersion = 3;
  static const int maxEntries = 200;

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, dbName);
    return openDatabase(
      path,
      version: dbVersion,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE IF NOT EXISTS entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            amount REAL NOT NULL,
            receiver TEXT NOT NULL,
            entry_date TEXT NOT NULL,
            source TEXT NOT NULL,
            raw_sms_body TEXT,
            created_at TEXT NOT NULL,
            is_previous_expense INTEGER NOT NULL DEFAULT 0,
            dedupe_key TEXT UNIQUE
          )
        ''');
        await database.execute('''
          CREATE TABLE IF NOT EXISTS rename_rules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            from_name TEXT NOT NULL UNIQUE,
            to_name TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE IF NOT EXISTS failed_parses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sms_datetime TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT,
            created_at TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE IF NOT EXISTS parser_settings (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            sender_marker TEXT NOT NULL,
            message_regex TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE IF NOT EXISTS diagnostics (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await _seedDefaults(database);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await database.execute('''
            CREATE TABLE IF NOT EXISTS parser_settings (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              sender_marker TEXT NOT NULL,
              message_regex TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 3) {
          await database.execute('''
            CREATE TABLE IF NOT EXISTS diagnostics (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        }
      },
      onOpen: (database) async {
        await database.rawQuery('PRAGMA busy_timeout=5000;');
        await _seedDefaults(database);
      },
    );
  }

  Future<void> _seedDefaults(Database database) async {
    await database.insert(
      'rename_rules',
      {'from_name': 'BOTTLE LAB TECHNOLOGIES P', 'to_name': 'Lunch'},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    final existing = Sqflite.firstIntValue(await database.rawQuery(
      'SELECT COUNT(*) FROM entries WHERE is_previous_expense = 1',
    ));
    if (existing == 0) {
      final nowIso = DateTime.now().toIso8601String().split('.').first;
      await database.insert('entries', {
        'amount': 0.0,
        'receiver': 'Previous Expense',
        'entry_date': nowIso,
        'source': 'system',
        'created_at': nowIso,
        'is_previous_expense': 1,
      });
    }

    await database.insert(
      'parser_settings',
      {
        'id': 1,
        'sender_marker': ParserSettings.defaultSenderMarker,
        'message_regex': ParserSettings.defaultMessageRegex,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ---------------- Entries ----------------

  Future<List<ExpenseEntry>> getEntries({DateTime? start, DateTime? end}) async {
    final database = await db;
    String? where;
    List<Object?>? args;
    if (start != null && end != null) {
      where = 'entry_date >= ? AND entry_date < ?';
      args = [_iso(start), _iso(end)];
    }
    final rows = await database.query(
      'entries',
      where: where,
      whereArgs: args,
      orderBy: 'entry_date DESC, id DESC',
    );
    return rows.map((r) => ExpenseEntry.fromMap(r)).toList();
  }

  Future<List<ExpenseEntry>> getAllEntriesAscending() async {
    final database = await db;
    final rows = await database.query('entries', orderBy: 'entry_date ASC, id ASC');
    return rows.map((r) => ExpenseEntry.fromMap(r)).toList();
  }

  Future<int> insertManualEntry(ExpenseEntry entry) async {
    final database = await db;
    late int id;
    await database.transaction((txn) async {
      final map = entry.toMap()..remove('id');
      id = await txn.insert('entries', map);
      await _enforceCap(txn);
    });
    return id;
  }

  Future<void> updateEntry(ExpenseEntry entry) async {
    if (entry.id == null) {
      throw ArgumentError('Entry must have an id to update');
    }
    final database = await db;
    final map = entry.toMap()..remove('id');
    await database.update('entries', map, where: 'id = ?', whereArgs: [entry.id]);
  }

  Future<void> deleteEntry(int id) async {
    final database = await db;
    await database.delete(
      'entries',
      where: 'id = ? AND is_previous_expense = 0',
      whereArgs: [id],
    );
  }

  Future<void> _enforceCap(DatabaseExecutor txn) async {
    final count = Sqflite.firstIntValue(await txn.rawQuery(
          'SELECT COUNT(*) FROM entries WHERE is_previous_expense = 0',
        )) ??
        0;

    if (count <= maxEntries) return;

    final overflow = count - maxEntries;
    final oldest = await txn.query(
      'entries',
      columns: ['id', 'amount'],
      where: 'is_previous_expense = 0',
      orderBy: 'entry_date ASC, id ASC',
      limit: overflow,
    );
    if (oldest.isEmpty) return;

    final ids = oldest.map((r) => r['id'] as int).toList();
    final foldedAmount = oldest.fold<double>(0.0, (s, r) => s + (r['amount'] as num).toDouble());

    final placeholders = List.filled(ids.length, '?').join(',');
    await txn.rawDelete('DELETE FROM entries WHERE id IN ($placeholders)', ids);
    final rowsUpdated = await txn.rawUpdate(
      'UPDATE entries SET amount = amount + ? WHERE is_previous_expense = 1',
      [foldedAmount],
    );
    if (rowsUpdated == 0) {
      final nowIso = DateTime.now().toIso8601String().split('.').first;
      await txn.insert('entries', {
        'amount': foldedAmount,
        'receiver': 'Previous Expense',
        'entry_date': nowIso,
        'source': 'system',
        'created_at': nowIso,
        'is_previous_expense': 1,
      });
    }
  }

  // ---------------- Rename rules ----------------

  Future<List<RenameRule>> getRenameRules() async {
    final database = await db;
    final rows = await database.query('rename_rules', orderBy: 'from_name ASC');
    return rows.map((r) => RenameRule.fromMap(r)).toList();
  }

  Future<void> addRenameRule(String from, String to, {bool applyToExisting = true}) async {
    final database = await db;
    await database.insert(
      'rename_rules',
      {'from_name': from.trim(), 'to_name': to.trim()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (applyToExisting) {
      await database.rawUpdate(
        'UPDATE entries SET receiver = ? WHERE UPPER(receiver) = UPPER(?) AND is_previous_expense = 0',
        [to.trim(), from.trim()],
      );
    }
  }

  Future<void> deleteRenameRule(int id) async {
    final database = await db;
    await database.delete('rename_rules', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- Failed parses ----------------

  Future<List<FailedParse>> getFailedParses() async {
    final database = await db;
    final rows = await database.query('failed_parses', orderBy: 'id DESC');
    return rows.map((r) => FailedParse.fromMap(r)).toList();
  }

  Future<void> deleteFailedParse(int id) async {
    final database = await db;
    await database.delete('failed_parses', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- Parser settings ----------------

  Future<ParserSettings> getParserSettings() async {
    final database = await db;
    final rows = await database.query('parser_settings', where: 'id = 1', limit: 1);
    if (rows.isEmpty) {
      return ParserSettings(
        senderMarker: ParserSettings.defaultSenderMarker,
        messageRegex: ParserSettings.defaultMessageRegex,
      );
    }
    return ParserSettings.fromMap(rows.first);
  }

  Future<void> updateParserSettings(String senderMarker, String messageRegex) async {
    final database = await db;
    await database.insert(
      'parser_settings',
      {
        'id': 1,
        'sender_marker': senderMarker.trim(),
        'message_regex': messageRegex.trim(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> resetParserSettings() async {
    await updateParserSettings(
      ParserSettings.defaultSenderMarker,
      ParserSettings.defaultMessageRegex,
    );
  }

  // ---------------- Diagnostics ----------------

  /// Read-only from the Dart side -- only the native receiver writes to
  /// this table. Lets you check whether the receiver has run recently at
  /// all, independent of whether parsing succeeded.
  Future<DiagnosticsInfo> getDiagnostics() async {
    final database = await db;
    final rows = await database.query('diagnostics');
    DateTime? lastBroadcastAt;
    int totalBroadcasts = 0;
    for (final row in rows) {
      final key = row['key'] as String;
      final value = row['value'] as String;
      if (key == 'last_broadcast_at') {
        lastBroadcastAt = DateTime.tryParse(value);
      } else if (key == 'total_broadcasts') {
        totalBroadcasts = int.tryParse(value) ?? 0;
      }
    }
    return DiagnosticsInfo(lastBroadcastAt: lastBroadcastAt, totalBroadcasts: totalBroadcasts);
  }

  String _iso(DateTime d) => d.toIso8601String().split('.').first;
}