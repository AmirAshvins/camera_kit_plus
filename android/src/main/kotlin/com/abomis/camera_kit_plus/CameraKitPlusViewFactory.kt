package com.abomis.camera_kit_plus

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class CameraKitPlusViewFactory(private val messenger: BinaryMessenger, private val plugin: CameraKitPlusPlugin) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, id: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<String, Any?>
        val focusRequired = creationParams?.get("focusRequired") as? Boolean ?: true
        return CameraKitPlusView(context, messenger, plugin, focusRequired)
    }
}
