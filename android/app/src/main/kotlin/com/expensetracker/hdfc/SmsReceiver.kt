package com.expensetracker.hdfc

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.telephony.SmsMessage
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Fires only when a new SMS arrives (manifest-registered receiver on the
 * protected SMS_RECEIVED broadcast). There is no service, no polling loop,
 * and nothing running between messages — this process wakes up, does a few
 * milliseconds of parsing + a SQLite write, and goes back to sleep.
 *
 * The sender filter and message pattern are no longer hardcoded — they're
 * read from the `parser_settings` row on every broadcast, so changes made
 * in the app's Parser Settings screen take effect on the very next SMS
 * without needing a rebuild.
 */
class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        try {
            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            if (messages.isNullOrEmpty()) return

            val db = ExpenseDbHelper.getInstance(context)
            val settings = db.getParserSettings()
            val senderMarker = settings.senderMarker.trim().ifEmpty {
                ExpenseDbHelper.DEFAULT_SENDER_MARKER
            }

            // A single logical SMS can arrive as multiple PDU parts (long
            // messages). Group by sender+timestamp and concatenate bodies
            // so we parse ONE reconstructed message, not fragments.
            val groups = LinkedHashMap<String, MutableList<SmsMessage>>()
            for (msg in messages) {
                val key = "${msg.originatingAddress}|${msg.timestampMillis}"
                groups.getOrPut(key) { mutableListOf() }.add(msg)
            }

            for ((_, parts) in groups) {
                val sender = parts.first().originatingAddress ?: continue
                if (!sender.uppercase(Locale.ROOT).contains(senderMarker.uppercase(Locale.ROOT))) continue

                val fullBody = parts.joinToString(separator = "") { it.messageBody ?: "" }
                val smsTimestampMillis = parts.first().timestampMillis
                handleMessage(db, settings, sender, fullBody, smsTimestampMillis)
            }
        } catch (e: Exception) {
            // Never let a malformed SMS crash the receiver.
            runCatching {
                ExpenseDbHelper.getInstance(context).logFailedParse(
                    smsDateTimeIso = ExpenseDbHelper.nowIso(),
                    title = "Unhandled receiver error",
                    body = e.message ?: "unknown error"
                )
            }
        }
    }

    private fun compileRegex(pattern: String): Regex? = try {
        Regex(pattern, setOf(RegexOption.IGNORE_CASE))
    } catch (e: Exception) {
        null
    }

    private fun handleMessage(
        db: ExpenseDbHelper,
        settings: ParserSettings,
        sender: String,
        body: String,
        timestampMillis: Long
    ) {
        val isoDateTime = millisToIso(timestampMillis)

        var pattern = compileRegex(settings.messageRegex)
        var usedFallback = false
        if (pattern == null) {
            // The user's custom pattern doesn't compile -- fall back to the
            // built-in default so tracking doesn't silently stop while they
            // fix it in Parser Settings.
            pattern = compileRegex(ExpenseDbHelper.DEFAULT_MESSAGE_REGEX)
            usedFallback = true
        }

        val match = pattern?.find(body)

        if (match == null || match.groupValues.size < 3) {
            db.logFailedParse(
                smsDateTimeIso = isoDateTime,
                title = if (usedFallback)
                    "Unparsed SMS (custom pattern invalid, default also didn't match) from $sender"
                else
                    "Unparsed SMS from $sender",
                body = body
            )
            return
        }

        val amountStr = match.groupValues[1].replace(",", "")
        val amount = amountStr.toDoubleOrNull()
        var receiver = match.groupValues[2].trim()

        if (amount == null || receiver.isEmpty()) {
            db.logFailedParse(
                smsDateTimeIso = isoDateTime,
                title = "Malformed SMS from $sender (matched pattern but bad amount/receiver)",
                body = body
            )
            return
        }

        receiver = db.applyRenameRule(receiver)
        val dedupeKey = buildDedupeKey(sender, timestampMillis, amountStr, receiver)

        // Debit = positive, per the tracker's sign convention.
        db.insertSmsEntry(
            amount = amount,
            receiver = receiver,
            entryDateIso = isoDateTime,
            rawBody = body,
            dedupeKey = dedupeKey
        )

        if (usedFallback) {
            db.logFailedParse(
                smsDateTimeIso = isoDateTime,
                title = "Note: your custom parser pattern was invalid — this message was " +
                    "parsed with the built-in default instead. Fix it in Parser Settings.",
                body = body
            )
        }
    }

    private fun buildDedupeKey(sender: String, timestampMillis: Long, amount: String, receiver: String): String {
        val raw = "$sender|$timestampMillis|$amount|$receiver"
        val digest = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun millisToIso(millis: Long): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        sdf.timeZone = TimeZone.getDefault()
        return sdf.format(Date(millis))
    }
}
