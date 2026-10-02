package com.expensetracker.hdfc

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.provider.Telephony
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.expensetracker.hdfc/permissions"
    private val receiveSmsRequestCode = 4321
    private val readSmsRequestCode = 4322
    private var pendingReceiveSmsResult: MethodChannel.Result? = null
    private var pendingReadSmsResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasSmsPermission" -> result.success(hasReceiveSmsPermission())
                    "requestSmsPermission" -> requestSms(
                        permission = Manifest.permission.RECEIVE_SMS,
                        prefsKey = "requested_receive_sms",
                        requestCode = receiveSmsRequestCode,
                        hasPermission = ::hasReceiveSmsPermission,
                        setPending = { pendingReceiveSmsResult = it },
                        result = result
                    )
                    "hasReadSmsPermission" -> result.success(hasReadSmsPermission())
                    "requestReadSmsPermission" -> requestSms(
                        permission = Manifest.permission.READ_SMS,
                        prefsKey = "requested_read_sms",
                        requestCode = readSmsRequestCode,
                        hasPermission = ::hasReadSmsPermission,
                        setPending = { pendingReadSmsResult = it },
                        result = result
                    )
                    "openAppSettings" -> {
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.fromParts("package", packageName, null)
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    "getDbFileName" -> result.success(ExpenseDbHelper.dbFileNameFor(this))
                    "runDailyBackupCheck" -> {
                        Thread {
                            ExpenseDbHelper.getInstance(this).maybeRunDailyBackup(this)
                            runOnUiThread { result.success(null) }
                        }.start()
                    }
                    "exportDatabaseNow" -> {
                        Thread {
                            val fileName = ExpenseDbHelper.getInstance(this).exportNow(this)
                            runOnUiThread { result.success(fileName) }
                        }.start()
                    }
                    "scanSmsInboxForHdfc" -> {
                        if (!hasReadSmsPermission()) {
                            result.error("PERMISSION_DENIED", "READ_SMS permission not granted", null)
                            return@setMethodCallHandler
                        }
                        val args = call.arguments as? Map<*, *>
                        val startMillis = (args?.get("start") as? Number)?.toLong() ?: 0L
                        val endMillis = (args?.get("end") as? Number)?.toLong() ?: System.currentTimeMillis()
                        Thread {
                            val summary = scanInboxForHdfc(startMillis, endMillis)
                            runOnUiThread { result.success(summary) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Shared request flow for both RECEIVE_SMS and READ_SMS. Android will
     * silently refuse to show its own permission dialog a second time once
     * the person has denied it before ("permanently denied") -- calling
     * requestPermissions() again in that state just re-fires the callback
     * with DENIED and nothing visible happens, which is exactly the "Grant
     * button doesn't do anything" symptom. This detects that state (via a
     * remembered "we've asked before" flag, since shouldShowRequestPermission
     * Rationale() alone can't tell "never asked" apart from "permanently
     * denied") and sends the person to the app's system settings screen
     * instead, where the toggle can still be flipped manually.
     */
    private fun requestSms(
        permission: String,
        prefsKey: String,
        requestCode: Int,
        hasPermission: () -> Boolean,
        setPending: (MethodChannel.Result?) -> Unit,
        result: MethodChannel.Result
    ) {
        if (hasPermission()) {
            result.success(true)
            return
        }

        val prefs = getSharedPreferences("permission_state", MODE_PRIVATE)
        val askedBefore = prefs.getBoolean(prefsKey, false)
        val canShowRationale = ActivityCompat.shouldShowRequestPermissionRationale(this, permission)

        if (askedBefore && !canShowRationale) {
            // Permanently denied -- Android will not show its own dialog
            // again. Send the person to Settings instead of doing nothing.
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            result.success(false)
            return
        }

        prefs.edit().putBoolean(prefsKey, true).apply()
        setPending(result)
        ActivityCompat.requestPermissions(this, arrayOf(permission), requestCode)
    }

    private fun hasReceiveSmsPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECEIVE_SMS) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasReadSmsPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Scans the SMS inbox (not sent messages) for anything containing
     * "HDFC" (case-insensitive) within [startMillis, endMillis], regardless
     * of sender, and runs each one through the same parser the live
     * receiver uses. Already-imported transactions are silently skipped by
     * the existing dedupe-key uniqueness constraint.
     */
    private fun scanInboxForHdfc(startMillis: Long, endMillis: Long): Map<String, Int> {
        val db = ExpenseDbHelper.getInstance(this)
        val settings = db.getParserSettings()

        var scanned = 0
        var inserted = 0
        var unparsed = 0

        val uri = Telephony.Sms.Inbox.CONTENT_URI
        val projection = arrayOf(
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE
        )
        val selection = "${Telephony.Sms.DATE} >= ? AND ${Telephony.Sms.DATE} <= ?"
        val selectionArgs = arrayOf(startMillis.toString(), endMillis.toString())
        val sortOrder = "${Telephony.Sms.DATE} ASC"

        contentResolver.query(uri, projection, selection, selectionArgs, sortOrder)?.use { cursor ->
            val addressIdx = cursor.getColumnIndex(Telephony.Sms.ADDRESS)
            val bodyIdx = cursor.getColumnIndex(Telephony.Sms.BODY)
            val dateIdx = cursor.getColumnIndex(Telephony.Sms.DATE)
            if (addressIdx < 0 || bodyIdx < 0 || dateIdx < 0) return@use

            while (cursor.moveToNext()) {
                val address = cursor.getString(addressIdx) ?: continue
                val body = cursor.getString(bodyIdx) ?: continue
                val date = cursor.getLong(dateIdx)

                if (!body.contains("HDFC", ignoreCase = true)) continue

                scanned++
                val wasInserted = SmsParser.handleMessage(db, settings, address, body, date)
                if (wasInserted) inserted++ else unparsed++
            }
        }

        return mapOf("scanned" to scanned, "inserted" to inserted, "unparsed" to unparsed)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        when (requestCode) {
            receiveSmsRequestCode -> {
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                pendingReceiveSmsResult?.success(granted)
                pendingReceiveSmsResult = null
            }
            readSmsRequestCode -> {
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                pendingReadSmsResult?.success(granted)
                pendingReadSmsResult = null
            }
            else -> super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
}