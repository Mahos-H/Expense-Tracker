package com.expensetracker.hdfc

import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Shared parsing core used by both the live broadcast receiver (SmsReceiver)
 * and the manual "Import from SMS" bulk scan (MainActivity). A message is
 * parsed identically no matter which path found it -- same regex, same
 * dedupe key formula, same rename rules, same cap enforcement.
 */
object SmsParser {

    fun compileRegex(pattern: String): Regex? = try {
        Regex(pattern, setOf(RegexOption.IGNORE_CASE))
    } catch (e: Exception) {
        null
    }

    /** Returns true if at least one transaction was inserted from this message. */
    fun handleMessage(
        db: ExpenseDbHelper,
        settings: ParserSettings,
        sender: String,
        body: String,
        timestampMillis: Long
    ): Boolean {
        val isoDateTime = millisToIso(timestampMillis)

        var pattern = compileRegex(settings.messageRegex)
        var usedFallback = false
        if (pattern == null) {
            pattern = compileRegex(ExpenseDbHelper.DEFAULT_MESSAGE_REGEX)
            usedFallback = true
        }

        if (pattern == null) {
            db.logFailedParse(isoDateTime, "Parser pattern completely broken from $sender", body)
            return false
        }

        val matches = pattern.findAll(body).toList()

        if (matches.isEmpty()) {
            db.logFailedParse(
                smsDateTimeIso = isoDateTime,
                title = if (usedFallback)
                    "Unparsed SMS (custom pattern invalid, default also didn't match) from $sender"
                else
                    "Unparsed SMS from $sender",
                body = body
            )
            return false
        }

        var anyInserted = false
        for (match in matches) {
            if (match.groupValues.size < 3) continue

            val amountStr = match.groupValues[1].replace(",", "")
            val amount = amountStr.toDoubleOrNull()
            var receiver = match.groupValues[2].trim()

            if (amount == null || receiver.isEmpty()) {
                db.logFailedParse(
                    smsDateTimeIso = isoDateTime,
                    title = "Malformed SMS from $sender (matched pattern but bad amount/receiver)",
                    body = match.value
                )
                continue
            }

            receiver = db.applyRenameRule(receiver)
            val dedupeKey = buildDedupeKey(sender, timestampMillis, amountStr, receiver, match.range.first)

            db.insertSmsEntry(
                amount = amount,
                receiver = receiver,
                entryDateIso = isoDateTime,
                rawBody = match.value,
                dedupeKey = dedupeKey
            )
            anyInserted = true
        }

        if (usedFallback && anyInserted) {
            db.logFailedParse(
                smsDateTimeIso = isoDateTime,
                title = "Note: your custom parser pattern was invalid — this message was " +
                    "parsed with the built-in default instead. Fix it in Parser Settings.",
                body = body
            )
        }

        return anyInserted
    }

    fun buildDedupeKey(
        sender: String,
        timestampMillis: Long,
        amount: String,
        receiver: String,
        matchPosition: Int
    ): String {
        val raw = "$sender|$timestampMillis|$amount|$receiver|$matchPosition"
        val digest = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    fun millisToIso(millis: Long): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        sdf.timeZone = TimeZone.getDefault()
        return sdf.format(Date(millis))
    }
}