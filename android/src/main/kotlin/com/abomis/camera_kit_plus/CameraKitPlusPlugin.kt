package com.abomis.camera_kit_plus

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

/** CameraKitPlusPlugin */
class CameraKitPlusPlugin: FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel
  private val listeners = mutableListOf<PluginRegistry.RequestPermissionsResultListener>()
  private var activity: Activity? = null
  private var pendingPermissionResult: Result? = null
  private val pluginPermissionRequestCode = 1002

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "camera_kit_plus")
    channel.setMethodCallHandler(this)

    flutterPluginBinding.platformViewRegistry.registerViewFactory(
      "camera-kit-plus-view",
      CameraKitPlusViewFactory(flutterPluginBinding.binaryMessenger, this)
    )
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
      "camera-kit-ocr-plus-view",
      CameraKitOcrPlusViewFactory(flutterPluginBinding.binaryMessenger, this)
    )
  }

  fun addListener(listener: PluginRegistry.RequestPermissionsResultListener) {
    listeners.add(listener)
  }

  fun removeListener(listener: PluginRegistry.RequestPermissionsResultListener) {
    listeners.remove(listener)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
      "getCameraPermission" -> getCameraPermission(result)
      else -> result.notImplemented()
    }
  }

  private fun getCameraPermission(result: Result) {
    val act = activity
    if (act == null) {
      result.success(false)
      return
    }
    if (ContextCompat.checkSelfPermission(act, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
      result.success(true)
      return
    }
    pendingPermissionResult = result
    ActivityCompat.requestPermissions(
      act,
      arrayOf(Manifest.permission.CAMERA),
      pluginPermissionRequestCode
    )
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addRequestPermissionsResultListener(this)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity()
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    activity = null
    pendingPermissionResult = null
    listeners.clear()
  }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
    if (requestCode == pluginPermissionRequestCode) {
      val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
      pendingPermissionResult?.success(granted)
      pendingPermissionResult = null
      return true
    }
    for (listener in listeners) {
      if (listener.onRequestPermissionsResult(requestCode, permissions, grantResults)) {
        return true
      }
    }
    return false
  }

}
