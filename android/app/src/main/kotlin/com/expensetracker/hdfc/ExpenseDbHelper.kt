package com.expensetracker.hdfc

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class ParserSettings(val senderMarker: String, val messageRegex: String)

/**
 * The database file this app opens is named after the app's own installed
 * versionName (e.g. "expense_tracker_1.0.3.db"), not a fixed name. This
 * means a version bump that updates the app IN PLACE leaves the previous
 * version's data file untouched on disk rather than silently reusing or
 * migrating it -- you decide when (and whether) to bring old data forward.
 * It does NOT protect against a full uninstall, which wipes the entire
 * private storage directory regardless of what's inside it -- that's what
 * the daily external backup (see maybeRunDailyBackup) is for.
 */
class ExpenseDbHelper private constructor(context: Context, dbFileName: String) :
    SQLiteOpenHelper(context.applicationContext, dbFileName, null, DB_VERSION) {

    companion object {
        // Historical filename used before per-version naming existed.
        // Not opened by current code -- kept only as a reference for manual
        // recovery (e.g. via adb) of anything created before this change.
        const val LEGACY_DB_NAME = "expense_tracker.db"

        const val DB_VERSION = 3
        const val MAX_ENTRIES = 300
        const val MAX_FAILED_PARSES = 100

        const val DEFAULT_SENDER_MARKER = "HDFC"
        const val DEFAULT_MESSAGE_REGEX =
            """Sent\s+(?:Rs\.?|INR)?\s*([0-9][0-9,]*\.\d{2})\s+From\s+HDFC\s+Bank\s+A/?C\s+\S+\s+To\s+(.+?)\s+On\s+(\d{1,2}/\d{1,2}/\d{2,4})"""

        private const val DAILY_BACKUP_FILE_NAME = "expense_tracker_daily_backup.db"

        @Volatile private var instance: ExpenseDbHelper? = null

        fun getInstance(context: Context): ExpenseDbHelper =
            instance ?: synchronized(this) {
                instance ?: ExpenseDbHelper(context, dbFileNameFor(context)).also { instance = it }
            }

        /** Single source of truth for the db filename, derived from the
         * actual installed app version -- both Kotlin and Dart call this
         * (Dart via the "getDbFileName" channel method) so they can never
         * disagree on which file to open. */
        fun dbFileNameFor(context: Context): String {
            val versionName = try {
                context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "unknown"
            } catch (e: Exception) {
                "unknown"
            }
            val safeVersion = versionName.replace(Regex("[^A-Za-z0-9_.-]"), "_")
            return "expense_tracker_$safeVersion.db"
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

        // One-time upgrade: if the sender filter is still exactly the OLD
        // built-in default ("HDFCBK"), move it to the new, broader default
        // ("HDFC"). A value you customized yourself is left untouched.
        val cursor = db.rawQuery(
            "SELECT sender_marker FROM parser_settings WHERE id = 1 LIMIT 1", null
        )
        val currentMarker = if (cursor.moveToFirst()) cursor.getString(0) else null
        cursor.close()
        if (currentMarker == "HDFCBK") {
            db.execSQL(
                "UPDATE parser_settings SET sender_marker = ? WHERE id = 1",
                arrayOf(DEFAULT_SENDER_MARKER)
            )
        }
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

    fun recordBroadcastReceived() {
        try {
            val database = writableDatabase
            val cv = ContentValues().apply {
                put("key", "last_broadcast_at")
                put("value", nowIso())
            }
            database.insertWithOnConflict("diagnostics", null, cv, SQLiteDatabase.CONFLICT_REPLACE)
        } catch (e: Exception) {
            Log.e("ExpenseDbHelper", "Failed to record broadcast heartbeat", e)
        }
    }

    /**
     * Runs at most once per calendar day. Makes a clean, atomic snapshot of
     * the live database via SQLite's own VACUUM INTO (so a backup can never
     * be a half-written/corrupt copy), then copies that snapshot to the
     * phone's public Downloads folder -- genuinely outside this app's
     * private storage, so it survives even a full uninstall.
     *
     * Called both from SmsReceiver (so it happens even if the app itself is
     * never opened) and from the app on every normal launch, as a backstop.
     */
    fun maybeRunDailyBackup(context: Context) {
        try {
            val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
            val cursor = readableDatabase.rawQuery(
                "SELECT value FROM diagnostics WHERE key = 'last_backup_date'", null
            )
            val lastDate = if (cursor.moveToFirst()) cursor.getString(0) else null
            cursor.close()
            if (lastDate == today) return

            val tempFile = File(context.cacheDir, "expense_tracker_backup_tmp.db")
            if (tempFile.exists()) tempFile.delete()

            writableDatabase.execSQL("VACUUM INTO ?", arrayOf(tempFile.absolutePath))

            val written = writeFileToDownloads(context, tempFile, DAILY_BACKUP_FILE_NAME)
            tempFile.delete()

            if (written) {
                val cv = ContentValues().apply {
                    put("key", "last_backup_date")
                    put("value", today)
                }
                writableDatabase.insertWithOnConflict(
                    "diagnostics", null, cv, SQLiteDatabase.CONFLICT_REPLACE
                )
            }
        } catch (e: Exception) {
            Log.e("ExpenseDbHelper", "Daily backup failed", e)
        }
    }
    /**
     * On-demand export, separate from the once-a-day automatic backup.
     * Same clean VACUUM INTO snapshot, copied to Downloads under a
     * timestamped name so repeated exports never overwrite each other.
     * Returns the filename used, or null on failure.
     */
    fun exportNow(context: Context): String? {
        return try {
            val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val fileName = "expense_tracker_export_$timestamp.db"

            val tempFile = File(context.cacheDir, "expense_tracker_export_tmp.db")
            if (tempFile.exists()) tempFile.delete()

            writableDatabase.execSQL("VACUUM INTO ?", arrayOf(tempFile.absolutePath))

            val written = writeFileToDownloads(context, tempFile, fileName)
            tempFile.delete()

            if (written) fileName else null
        } catch (e: Exception) {
            Log.e("ExpenseDbHelper", "Manual export failed", e)
            null
        }
    }

    private fun writeFileToDownloads(context: Context, sourceFile: File, displayName: String): Boolean {
        return try {
            val resolver = context.contentResolver
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var existingUri: Uri? = null
                resolver.query(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    arrayOf(MediaStore.Downloads._ID),
                    "${MediaStore.Downloads.DISPLAY_NAME} = ?",
                    arrayOf(displayName),
                    null
                )?.use { c ->
                    if (c.moveToFirst()) {
                        val id = c.getLong(c.getColumnIndexOrThrow(MediaStore.Downloads._ID))
                        existingUri = ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id)
                    }
                }

                val uri = existingUri ?: run {
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                        put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                        put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    }
                    resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                } ?: return false

                resolver.openOutputStream(uri, "wt")?.use { out ->
                    sourceFile.inputStream().use { input -> input.copyTo(out) }
                } ?: return false
                true
            } else {
                @Suppress("DEPRECATION")
                val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                if (!downloadsDir.exists()) downloadsDir.mkdirs()
                val destFile = File(downloadsDir, displayName)
                sourceFile.inputStream().use { input ->
                    destFile.outputStream().use { output -> input.copyTo(output) }
                }
                true
            }
        } catch (e: Exception) {
            Log.e("ExpenseDbHelper", "Failed writing backup to Downloads", e)
            false
        }
    }

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
                SELECT id FROM failed_parses ORDER BY id DESC LIMIT $MAX_FAILED_PARSES
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