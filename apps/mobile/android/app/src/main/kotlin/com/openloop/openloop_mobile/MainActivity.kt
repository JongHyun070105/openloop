package com.openloop.openloop_mobile

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onNewIntent(intent: Intent) {
        if (intent.action != Intent.ACTION_SEND) {
            super.onNewIntent(intent)
            return
        }
        if (!canReadSharedContent(intent)) return

        try {
            super.onNewIntent(intent)
        } catch (_: Exception) {
            // A malicious or expired content URI must not terminate the app. Valid
            // Android share sheets supply a temporary read grant, and inaccessible
            // content is simply ignored rather than persisted or retried.
            Log.w(TAG, "Ignored inaccessible shared content")
        }
    }

    private fun canReadSharedContent(intent: Intent): Boolean {
        @Suppress("DEPRECATION")
        val stream = intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri ?: return true
        if (stream.scheme != ContentResolver.SCHEME_CONTENT) return true
        return try {
            contentResolver.openInputStream(stream)?.use { } != null
        } catch (_: Exception) {
            // Do not pass an inaccessible URI to receive_sharing_intent: its
            // resolver call can block the activity before it throws.
            Log.w(TAG, "Ignored inaccessible shared content")
            false
        }
    }

    private companion object {
        const val TAG = "OpenLoop"
    }
}
