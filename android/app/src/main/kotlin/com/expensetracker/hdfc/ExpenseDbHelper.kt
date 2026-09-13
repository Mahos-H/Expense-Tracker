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

class ExpenseDbHelper private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {

    companion object {
        const val DB_NAME = "expense_tracker.db"
        const val DB_VERSION = 3
        const val MAX_ENTRIES = 200

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
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS diagnostics (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
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
        if (oldVersion < 3) {
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS diagnostics (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """.trimIndent()
            )
        }
    }

    override fun onOpen(db: SQLiteDatabase) {
        super.onOpen(db)
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

    /** Records that the broadcast receiver actually ran, regardless of what
     * happened afterward -- this is the single fact that lets you tell
     * "the OS never delivered the SMS to this app" apart from "it arrived
     * but something downstream went wrong." Wrapped in its own try/catch so
     * a diagnostics failure can never take down the real parsing logic. */
    fun recordBroadcastReceived() {
        try {
            val database = writableDatabase
            database.beginTransaction()
            try {
                val cv = ContentValues().apply {
                    put("key", "last_broadcast_at")
                    put("value", nowIso())
                }
                database.insertWithOnConflict("diagnostics", null, cv, SQLiteDatabase.CONFLICT_REPLACE)

                val cursor = database.rawQuery(
                    "SELECT value FROM diagnostics WHERE key = 'total_broadcasts'", null
                )
                val current = if (cursor.moveToFirst()) cursor.getString(0).toIntOrNull() ?: 0 else 0
                cursor.close()
                val countCv = ContentValues().apply {
                    put("key", "total_broadcasts")
                    put("value", (current + 1).toString())
                }
                database.insertWithOnConflict("diagnostics", null, countCv, SQLiteDatabase.CONFLICT_REPLACE)

                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
        } catch (e: Exception) {
            Log.e("ExpenseDbHelper", "Failed to record broadcast heartbeat", e)
        }
    }

    /**
     * Inserts a new SMS-derived entry and enforces the 200-entry cap.
     * If the write itself fails for any reason, that failure is now
     * surfaced into Unparsed Messages -- previously it only went to
     * Logcat, which meant a correctly-parsed transaction could fail to
     * save and vanish without any trace visible on the phone itself.
     */
    fun insertSmsEntry(
        amount: Double,
        receiver: String,
        entryDateIso: String,
        rawBody: String,
        dedupeKey: String
    ) {
        val db = writableDatabase
        var succeeded = false
        var errorMessage: String? = null

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

            val rowId = db.insertWithOnConflict("entries", null, cv, SQLiteDatabase.CONFLICT_IGNORE)
            if (rowId != -1L) {
                enforceCapLocked(db)
            }
            db.setTransactionSuccessful()
            succeeded = true
        } catch (e: Exception) {
            Log.e("ExpenseDbHelper", "Failed to insert SMS entry", e)
            errorMessage = e.message
        } finally {
            db.endTransaction()
        }

        if (!succeeded) {
            runCatching {
                logFailedParse(
                    smsDateTimeIso = entryDateIso,
                    title = "Database error while saving a transaction from $receiver",
                    body = "$rawBody\n\n(Internal error: ${errorMessage ?: "unknown"})"
                )
            }
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

        db.execSQL(
            """
            DELETE FROM failed_parses WHERE id NOT IN (
                SELECT id FROM failed_parses ORDER BY id DESC LIMIT 300
            )
            """.trimIndent()
        )
    }

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
            val changesCursor = db.rawQuery("SELECT changes()", null)
            changesCursor.moveToFirst()
            val rowsChanged = changesCursor.getInt(0)
            changesCursor.close()
            if (rowsChanged == 0) {
                val cv = ContentValues().apply {
                    put("amount", foldedAmount)
                    put("receiver", "Previous Expense")
                    put("entry_date", nowIso())
                    put("source", "system")
                    put("created_at", nowIso())
                    put("is_previous_expense", 1)
                }
                db.insert("entries", null, cv)
            }
        }
    }
}