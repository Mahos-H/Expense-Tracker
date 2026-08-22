package com.expensetracker.hdfc

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class ParserSettings(val senderMarker: String, val messageRegex: String)

/**
 * This helper opens the EXACT same SQLite file that sqflite opens on the
 * Dart side (same filename, same default "databases" directory), so the
 * receiver can write new entries even when the Flutter engine isn't running,
 * and Flutter picks them up next time it queries.
 *
 * Both sides use `CREATE TABLE IF NOT EXISTS`, so whichever side happens to
 * touch the database first (usually Flutter, since the user must open the
 * app once to grant RECEIVE_SMS) creates the schema safely; the other side
 * is a no-op on create.
 */
class ExpenseDbHelper private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {

    companion object {
        const val DB_NAME = "expense_tracker.db"
        const val DB_VERSION = 2
        const val MAX_ENTRIES = 200

        // Kept identical to the Dart-side defaults in models/parser_settings.dart.
        const val DEFAULT_SENDER_MARKER = "HDFCBK"
        const val DEFAULT_MESSAGE_REGEX =
            """Sent\s+(?:Rs\.?|INR)?\s*([0-9][0-9,]*\.\d{2})\s+From\s+HDFC\s+Bank\s+A/?C\s+\S+\s+To\s+(.+?)\s+On\s+(\d{1,2}/\d{1,2}/\d{2,4})"""

        @Volatile private var instance: ExpenseDbHelper? = null

        fun getInstance(context: Context): ExpenseDbHelper =
            instance ?: synchronized(this) {
                instance ?: ExpenseDbHelper(context).also { instance = it }
            }

        fun nowIso(): String =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
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
            """.trimIndent()
        )

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS rename_rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                from_name TEXT NOT NULL UNIQUE,
                to_name TEXT NOT NULL
            )
            """.trimIndent()
        )

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS failed_parses (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sms_datetime TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT,
                created_at TEXT NOT NULL
            )
            """.trimIndent()
        )

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS parser_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                sender_marker TEXT NOT NULL,
                message_regex TEXT NOT NULL
            )
            """.trimIndent()
        )

        seedDefaults(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS parser_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    sender_marker TEXT NOT NULL,
                    message_regex TEXT NOT NULL
                )
                """.trimIndent()
            )
        }
    }

    override fun onOpen(db: SQLiteDatabase) {
        super.onOpen(db)
        // busy_timeout matters here: the receiver and the Flutter engine
        // both live in the SAME process but can hit the DB from different
        // threads at nearly the same moment (e.g. app opened right as an
        // SMS arrives). Rather than fail with "database is locked", each
        // writer waits up to 5s for the other's transaction to finish.
        db.rawQuery("PRAGMA busy_timeout=5000;", null).close()
        seedDefaults(db)
    }

    private fun seedDefaults(db: SQLiteDatabase) {
        val ruleCv = ContentValues().apply {
            put("from_name", "BOTTLE LAB TECHNOLOGIES P")
            put("to_name", "Lunch")
        }
        db.insertWithOnConflict("rename_rules", null, ruleCv, SQLiteDatabase.CONFLICT_IGNORE)

        val existing = db.rawQuery(
            "SELECT COUNT(*) FROM entries WHERE is_previous_expense = 1", null
        )
        existing.moveToFirst()
        val count = existing.getInt(0)
        existing.close()

        if (count == 0) {
            val entryCv = ContentValues().apply {
                put("amount", 0.00)
                put("receiver", "Previous Expense")
                put("entry_date", nowIso())
                put("source", "system")
                put("created_at", nowIso())
                put("is_previous_expense", 1)
            }
            db.insert("entries", null, entryCv)
        }

        val settingsCv = ContentValues().apply {
            put("id", 1)
            put("sender_marker", DEFAULT_SENDER_MARKER)
            put("message_regex", DEFAULT_MESSAGE_REGEX)
        }
        db.insertWithOnConflict("parser_settings", null, settingsCv, SQLiteDatabase.CONFLICT_IGNORE)
    }

    fun applyRenameRule(rawReceiver: String): String {
        val normalized = rawReceiver.trim()
        val cursor = readableDatabase.rawQuery(
            "SELECT to_name FROM rename_rules WHERE UPPER(from_name) = UPPER(?) LIMIT 1",
            arrayOf(normalized)
        )
        val result = if (cursor.moveToFirst()) cursor.getString(0) else normalized
        cursor.close()
        return result
    }

    /** Reads the current sender filter + message regex, editable from the app's
     * Parser Settings screen. Falls back to the built-in HDFC defaults if the
     * row is somehow missing. */
    fun getParserSettings(): ParserSettings {
        val cursor = readableDatabase.rawQuery(
            "SELECT sender_marker, message_regex FROM parser_settings WHERE id = 1 LIMIT 1", null
        )
        val result = if (cursor.moveToFirst()) {
            ParserSettings(cursor.getString(0), cursor.getString(1))
        } else {
            ParserSettings(DEFAULT_SENDER_MARKER, DEFAULT_MESSAGE_REGEX)
        }
        cursor.close()
        return result
    }

    /**
     * Inserts a new SMS-derived entry and enforces the 200-entry cap, all
     * inside one transaction. The UNIQUE(dedupe_key) constraint combined
     * with CONFLICT_IGNORE is what makes this safe against the classic
     * Android quirk where SMS_RECEIVED can occasionally be redelivered, or
     * where a dual-SIM/OEM ROM fires the broadcast twice: the second
     * attempt for the same logical message is dropped atomically by SQLite
     * itself, so there's no window for a race condition regardless of
     * thread timing.
     */
    fun insertSmsEntry(
        amount: Double,
        receiver: String,
        entryDateIso: String,
        rawBody: String,
        dedupeKey: String
    ) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val cv = ContentValues().apply {
                put("amount", amount)
                put("receiver", receiver)
                put("entry_date", entryDateIso)
                put("source", "sms")
                put("raw_sms_body", rawBody)
                put("created_at", nowIso())
                put("is_previous_expense", 0)
                put("dedupe_key", dedupeKey)
            }

            val rowId = db.insertWithOnConflict(
                "entries", null, cv, SQLiteDatabase.CONFLICT_IGNORE
            )

            if (rowId != -1L) {
                enforceCapLocked(db)
            }

            db.setTransactionSuccessful()
        } catch (e: Exception) {
            Log.e("ExpenseDbHelper", "Failed to insert SMS entry", e)
        } finally {
            db.endTransaction()
        }
    }

    fun logFailedParse(smsDateTimeIso: String, title: String, body: String) {
        val db = writableDatabase
        val cv = ContentValues().apply {
            put("sms_datetime", smsDateTimeIso)
            put("title", title)
            put("body", body)
            put("created_at", nowIso())
        }
        db.insert("failed_parses", null, cv)

        // Bounded log so a flood of promo/OTP SMS can't grow this forever.
        db.execSQL(
            """
            DELETE FROM failed_parses WHERE id NOT IN (
                SELECT id FROM failed_parses ORDER BY id DESC LIMIT 300
            )
            """.trimIndent()
        )
    }

    /**
     * Must run inside an active transaction on [db].
     * Trims non-anchor entries down to MAX_ENTRIES, folding the amount of
     * every pruned row into the "Previous Expense" anchor entry so the
     * all-time running total is mathematically unaffected by pruning —
     * only per-entry metadata (receiver name, exact SMS body, etc.) is lost.
     */
    private fun enforceCapLocked(db: SQLiteDatabase) {
        val countCursor = db.rawQuery(
            "SELECT COUNT(*) FROM entries WHERE is_previous_expense = 0", null
        )
        countCursor.moveToFirst()
        val total = countCursor.getInt(0)
        countCursor.close()

        if (total <= MAX_ENTRIES) return

        val overflow = total - MAX_ENTRIES
        val oldestCursor = db.rawQuery(
            """
            SELECT id, amount FROM entries
            WHERE is_previous_expense = 0
            ORDER BY entry_date ASC, id ASC
            LIMIT ?
            """.trimIndent(),
            arrayOf(overflow.toString())
        )

        var foldedAmount = 0.0
        val idsToDelete = mutableListOf<Long>()
        while (oldestCursor.moveToNext()) {
            idsToDelete.add(oldestCursor.getLong(0))
            foldedAmount += oldestCursor.getDouble(1)
        }
        oldestCursor.close()

        if (idsToDelete.isNotEmpty()) {
            val placeholders = idsToDelete.joinToString(",") { "?" }
            db.execSQL(
                "DELETE FROM entries WHERE id IN ($placeholders)",
                idsToDelete.map { it as Any }.toTypedArray()
            )
            db.execSQL(
                "UPDATE entries SET amount = amount + ? WHERE is_previous_expense = 1",
                arrayOf(foldedAmount)
            )
        }
    }
}
