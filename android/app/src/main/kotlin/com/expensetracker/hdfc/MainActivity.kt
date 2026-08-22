package com.expensetracker.hdfc

import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * We deliberately avoid a generic "sms permission" plugin here. Those
 * typically request READ_SMS / SEND_SMS / RECEIVE_SMS as a bundle, which is
 * far more than this app needs. We only ever ask for RECEIVE_SMS — the app
 * never reads the SMS inbox and never sends SMS — which keeps the runtime
 * permission dialog honest and the attack surface small.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.expensetracker.hdfc/permissions"
    private val smsPermissionRequestCode = 4321
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasSmsPermission" -> result.success(hasPermission())
                    "requestSmsPermission" -> {
                        if (hasPermission()) {
                            result.success(true)
                        } else {
                            pendingResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.RECEIVE_SMS),
                                smsPermissionRequestCode
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECEIVE_SMS) ==
            PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == smsPermissionRequestCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingResult?.success(granted)
            pendingResult = null
        } else {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
}
