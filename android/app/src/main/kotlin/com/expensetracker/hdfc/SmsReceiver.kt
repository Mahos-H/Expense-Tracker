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
 * and nothing running between messages.
 *
 * The sender filter and message pattern are read from `parser_settings` on
 * every broadcast (editable via the app's Parser Settings screen).
 */
class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val db = ExpenseDbHelper.getInstance(context)
        // Recorded unconditionally, before any filtering: this is the fact
        // that lets you check, after the fact, whether the OS delivered
        // this broadcast to the app at all around the time an SMS arrived.
        db.recordBroadcastReceived()

        try {
            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            if (messages.isNullOrEmpty()) return

            val settings = db.getParserSettings()
            val senderMarker = settings.senderMarker.trim().ifEmpty {
                ExpenseDbHelper.DEFAULT_SENDER_MARKER
            }

            // Group strictly by sender -- NOT by timestamp. SMS PDU
            // timestamps only carry whole-second precision (a limit of the
            // SMS protocol itself, not an Android quirk), so several
            // genuinely distinct transactions delivered in a burst -- e.g.
            // after the phone was offline or the app hadn't been opened in
            // a while -- can share an identical timestamp down to the
            // millisecond. Splitting groups on timestamp equality used to
            // cause unrelated messages to get concatenated together and
            // parsed as one, which silently kept only the first transaction
            // with no failure logged anywhere.
            val groups = LinkedHashMap<String, MutableList<SmsMessage>>()
            for (msg in messages) {
                val key = msg.originatingAddress ?: continue
                groups.getOrPut(key) { mutableListOf() }.add(msg)
            }

            for ((sender, parts) in groups) {
                if (!sender.uppercase(Locale.ROOT).contains(senderMarker.uppercase(Locale.ROOT))) continue

                // A newline between parts is harmless for a genuine
                // multi-part message (the pattern's \s+ absorbs it same as
                // a space) and gives a little extra insurance against a
                // spurious match spanning the boundary between two
                // genuinely separate bundled messages.
                val fullBody = parts.joinToString(separator = "\n") { it.messageBody ?: "" }
                val smsTimestampMillis = parts.first().timestampMillis
                handleMessage(db, settings, sender, fullBody, smsTimestampMillis)
            }
        } catch (e: Exception) {
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

        if (pattern == null) {
            db.logFailedParse(isoDateTime, "Parser pattern completely broken from $sender", body)
            return
        }

        // findAll, not find: this is what actually fixes the "burst of
        // transactions arriving together" problem. If the reconstructed
        // body contains more than one "Sent ... To ... On ..." block --
        // whether that's a real multi-part SMS or several distinct
        // messages that got bundled into the same broadcast -- every one
        // of them gets matched and turned into its own entry, instead of
        // only the first being kept and the rest silently disappearing.
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
            return
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
            // Match position is folded into the dedupe key too, so that if
            // two distinct transactions in the same burst happen to have
            // identical amount + receiver (plausible -- same shop, same
            // price, twice in a row), they don't get mistaken for the same
            // transaction and one silently dropped.
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
    }

    private fun buildDedupeKey(
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

    private fun millisToIso(millis: Long): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        sdf.timeZone = TimeZone.getDefault()
        return sdf.format(Date(millis))
    }
}