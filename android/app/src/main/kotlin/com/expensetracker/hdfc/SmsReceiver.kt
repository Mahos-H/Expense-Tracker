package com.expensetracker.hdfc

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.telephony.SmsMessage
import java.util.Locale

/**
 * Fires only when a new SMS arrives (manifest-registered receiver on the
 * protected SMS_RECEIVED broadcast). There is no service, no polling loop,
 * and nothing running between messages.
 *
 * The sender filter and message pattern are read from `parser_settings` on
 * every broadcast (editable via the app's Parser Settings screen). Every
 * message the receiver sees gets logged to the recent-activity list in
 * Unparsed Messages, whether or not it came from a tracked sender.
 *
 * Actual regex parsing lives in SmsParser.kt, shared with the manual
 * "Import from SMS" bulk scan in MainActivity.
 */
class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return


        val db = ExpenseDbHelper.getInstance(context)
        db.recordBroadcastReceived()
        db.maybeRunDailyBackup(context)
        val messages = try {
            Telephony.Sms.Intents.getMessagesFromIntent(intent)
        } catch (e: Exception) {
            runCatching {
                db.logFailedParse(
                    ExpenseDbHelper.nowIso(),
                    "Failed to read an incoming SMS",
                    e.message ?: "unknown error"
                )
            }
            return
        }
        if (messages.isNullOrEmpty()) return

        val settings = try {
            db.getParserSettings()
        } catch (e: Exception) {
            runCatching {
                db.logFailedParse(
                    ExpenseDbHelper.nowIso(),
                    "Failed to read parser settings",
                    e.message ?: "unknown error"
                )
            }
            return
        }
        val senderMarker = settings.senderMarker.trim().ifEmpty {
            ExpenseDbHelper.DEFAULT_SENDER_MARKER
        }

        // Group strictly by sender -- not by timestamp, since SMS PDU
        // timestamps only carry whole-second precision and two genuinely
        // distinct messages can share one.
        val groups = LinkedHashMap<String, MutableList<SmsMessage>>()
        for (msg in messages) {
            val key = msg.originatingAddress ?: continue
            groups.getOrPut(key) { mutableListOf() }.add(msg)
        }

        for ((sender, parts) in groups) {
            // Each sender's message is handled inside its own try/catch, so
            // one bad message can never prevent another message delivered
            // in the same broadcast from being processed.
            try {
                val fullBody = parts.joinToString(separator = "\n") { it.messageBody ?: "" }
                val smsTimestampMillis = parts.first().timestampMillis
                val senderMatches = sender.uppercase(Locale.ROOT)
                    .contains(senderMarker.uppercase(Locale.ROOT))

                if (!senderMatches) {
                    // Every message gets logged here now, not just ones
                    // that resemble a bank SMS -- this is a simple, bounded
                    // recent-activity view of everything the receiver has
                    // seen, so you can always tell whether a given SMS
                    // reached the app at all and why it wasn't tracked.
                    db.logFailedParse(
                        smsDateTimeIso = SmsParser.millisToIso(smsTimestampMillis),
                        title = "Not from a tracked sender (\"$sender\", filter looks for \"$senderMarker\")",
                        body = fullBody
                    )
                    continue
                }

                SmsParser.handleMessage(db, settings, sender, fullBody, smsTimestampMillis)
            } catch (e: Exception) {
                runCatching {
                    db.logFailedParse(
                        smsDateTimeIso = ExpenseDbHelper.nowIso(),
                        title = "Unhandled error processing a message from $sender",
                        body = e.message ?: "unknown error"
                    )
                }
            }
        }
    }
}