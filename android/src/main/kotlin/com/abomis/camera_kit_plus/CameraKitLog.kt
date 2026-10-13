package com.abomis.camera_kit_plus

import android.util.Log

/// Console diagnostics for Camera Kit. Off until the host calls `setSilentLogs`.
object CameraKitLog {
    var silent: Boolean = true

    fun d(tag: String, message: String) {
        if (!silent) Log.d(tag, message)
    }

    fun w(tag: String, message: String) {
        if (!silent) Log.w(tag, message)
    }

    fun e(tag: String, message: String, throwable: Throwable? = null) {
        if (silent) return
        if (throwable != null) {
            Log.e(tag, message, throwable)
        } else {
            Log.e(tag, message)
        }
    }
}
