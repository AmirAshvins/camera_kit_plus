package com.abomis.camera_kit_plus

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.os.Build
import android.util.Log
import android.util.Size
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ExtendableBuilder
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.TorchState
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.Observer
import com.abomis.camera_kit_plus.Classes.CornerPointModel
import com.abomis.camera_kit_plus.Classes.LineModel
import com.google.gson.Gson
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RequiresApi(Build.VERSION_CODES.N)
class CameraKitOcrPlusView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    args: Map<String, Any?>?,
    private val plugin: CameraKitPlusPlugin?
) : FrameLayout(context), PlatformView, MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private val methodChannel = MethodChannel(messenger, "camera_kit_plus/view_$viewId")
    private lateinit var previewView: PreviewView
    private lateinit var linearLayout: FrameLayout
    private var cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private lateinit var textScanner: TextRecognizer
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var cameraSelector: CameraSelector? = null

    private var preview: Preview? = null
    private var imageCapture: ImageCapture? = null
    private var imageAnalysis: ImageAnalysis? = null
    private val REQUEST_CAMERA_PERMISSION = 1001

    private var lastOcrTs: Long = 0
    private val ocrMinIntervalMs = 333L

    private val focusRequired: Boolean = args?.get("focusRequired") as? Boolean ?: true
    private var showTextRectangles: Boolean = args?.get("showTextRectangles") as? Boolean ?: false
    private var ocrRotationOverride: Int? = null

    private var scaleDetector: ScaleGestureDetector? = null
    private var tapDetector: GestureDetector? = null
    private var pinchZoomRatio: Float = 1f

    private var macroEnabled: Boolean = false
    private var macroSupported: Boolean? = null

    /** Flutter platform channels require callbacks on the main thread. */
    private fun invokeOnMain(method: String, arguments: Any?) {
        ContextCompat.getMainExecutor(context).execute {
            methodChannel.invokeMethod(method, arguments)
        }
    }

    init {
        linearLayout = FrameLayout(context)
        linearLayout.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        linearLayout.setBackgroundColor(Color.BLACK)

        previewView = PreviewView(context)
        previewView.layoutParams =
            LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE

        methodChannel.setMethodCallHandler(this)
        plugin?.addListener(this)
        attachGestures()

        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                getActivity(context)!!,
                arrayOf(Manifest.permission.CAMERA),
                REQUEST_CAMERA_PERMISSION
            )
        } else {
            setupPreview()
        }

        addOnAttachStateChangeListener(object : OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) {
                resumeCamera(null)
            }

            override fun onViewDetachedFromWindow(v: View) {
                pauseCamera(null)
            }
        })
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode == REQUEST_CAMERA_PERMISSION) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                setupPreview()
            }
            return true
        }
        return false
    }

    private fun setupPreview() {
        if (previewView.parent != null) {
            return
        }
        linearLayout.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        linearLayout.addView(previewView)
        setupCameraSelector()
        setupCamera()
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        previewView.layout(0, 0, right - left, bottom - top)
    }

    private fun setupCameraSelector() {
        cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
        macroSupported = null
        macroEnabled = false
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bindUseCases(lifecycleOwner: LifecycleOwner) {
        val provider = cameraProvider ?: return
        val extBuilder: (ExtendableBuilder<*>) -> Unit = { builder ->
            val ext = Camera2Interop.Extender(builder)
            // CAF always runs so the preview is usable. focusRequired only gates tap-to-focus.
            if (macroEnabled) {
                // Match barcode view: MACRO goes on CONTROL_AF_MODE, not CONTROL_SCENE_MODE.
                ext.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_MACRO)
            } else {
                ext.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            }
        }

        val previewSize = Size(1280, 720)
        val analysisSize = Size(640, 480)
        val previewBuilder = Preview.Builder().setTargetResolution(previewSize)
        extBuilder(previewBuilder)
        preview = previewBuilder.build().also { it.setSurfaceProvider(previewView.surfaceProvider) }

        val analysisBuilder = ImageAnalysis.Builder()
            .setTargetResolution(analysisSize)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        extBuilder(analysisBuilder)
        imageAnalysis = analysisBuilder.build().also {
            it.setAnalyzer(cameraExecutor, ::processImageProxy)
        }

        val captureBuilder = ImageCapture.Builder()
            .setTargetResolution(previewSize)
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
        extBuilder(captureBuilder)
        imageCapture = captureBuilder.build()

        unbindOwnUseCases()
        try {
            camera = cameraSelector?.let {
                provider.bindToLifecycle(lifecycleOwner, it, preview, imageCapture, imageAnalysis)
            }
        } catch (exc: Exception) {
            Log.e("CameraX", "Use case binding failed", exc)
            return
        }

        macroSupported = isMacroSupported(camera)
        camera?.cameraInfo?.zoomState?.observe(lifecycleOwner, Observer { state ->
            state?.let { invokeOnMain("onZoomChanged", it.zoomRatio.toDouble()) }
        })
        invokeOnMain("onMacroChanged", buildMacroStatus())
    }

    private fun setupCamera() {
        val activity = getActivity(context) as? LifecycleOwner ?: return
        ensureTextScanner()
        if (cameraProvider != null) {
            bindUseCases(activity)
            return
        }

        ProcessCameraProvider.getInstance(context).addListener({
            cameraProvider = ProcessCameraProvider.getInstance(context).get()
            bindUseCases(activity)
        }, ContextCompat.getMainExecutor(context))
    }

    private fun ensureTextScanner() {
        if (::textScanner.isInitialized) return
        textScanner = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }

    private fun unbindOwnUseCases() {
        val provider = cameraProvider ?: return
        val bound = listOfNotNull(preview, imageCapture, imageAnalysis)
        if (bound.isNotEmpty()) {
            provider.unbind(*bound.toTypedArray())
        }
        camera = null
    }

    private fun takePicture(result: MethodChannel.Result) {
        val capture = imageCapture
        if (capture == null) {
            result.error("IMAGE_CAPTURE_UNAVAILABLE", "ImageCapture not ready", null)
            return
        }
        val file = File(context.cacheDir, "captured_image_${System.currentTimeMillis()}.jpg")
        capture.takePicture(
            ImageCapture.OutputFileOptions.Builder(file).build(),
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    result.success(file.absolutePath)
                }

                override fun onError(exception: ImageCaptureException) {
                    result.error("IMAGE_CAPTURE_FAILED", "Failed to capture image", exception.message)
                }
            }
        )
    }

    private fun getActivity(context: Context): Activity? {
        var currentContext = context
        while (currentContext is android.content.ContextWrapper) {
            if (currentContext is Activity) return currentContext
            currentContext = currentContext.baseContext
        }
        return null
    }

    @OptIn(ExperimentalGetImage::class)
    private fun processImageProxy(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }
        val now = System.currentTimeMillis()
        if (now - lastOcrTs < ocrMinIntervalMs) {
            imageProxy.close()
            return
        }
        lastOcrTs = now
        val rotation = ocrRotationOverride ?: imageProxy.imageInfo.rotationDegrees
        val image = InputImage.fromMediaImage(mediaImage, rotation)
        textScanner.process(image)
            .addOnSuccessListener { text ->
                val content = text.text.trim()
                if (content.isNotEmpty()) {
                    val lineModels: MutableList<LineModel> = ArrayList()
                    for (b in text.textBlocks) {
                        for (line in b.lines) {
                            val lineModel = LineModel(line.text)
                            val cps = line.cornerPoints
                            if (cps != null) {
                                for (p in cps) {
                                    lineModel.cornerPoints.add(
                                        CornerPointModel(p.x.toFloat(), p.y.toFloat())
                                    )
                                }
                            }
                            lineModels.add(lineModel)
                        }
                    }
                    val map: MutableMap<String, Any> = HashMap()
                    map["text"] = content
                    map["lines"] = lineModels
                    map["path"] = ""
                    map["orientation"] = rotation
                    invokeOnMain("onTextRead", Gson().toJson(map))
                }
            }
            .addOnFailureListener { Log.e("Text", "Failed to recognize text", it) }
            .addOnCompleteListener { imageProxy.close() }
    }

    private fun attachGestures() {
        scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                pinchZoomRatio = camera?.cameraInfo?.zoomState?.value?.zoomRatio ?: 1f
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val state = camera?.cameraInfo?.zoomState?.value ?: return false
                val newRatio = pinchZoomRatio * detector.scaleFactor
                camera?.cameraControl?.setZoomRatio(newRatio.coerceIn(state.minZoomRatio, state.maxZoomRatio))
                return true
            }
        })

        tapDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                if (focusRequired) focusAt(e.x, e.y)
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                resetZoom()
                return true
            }
        })

        // One listener feeds both pinch and double-tap detectors.
        linearLayout.setOnTouchListener { _, ev ->
            var handled = scaleDetector?.onTouchEvent(ev) ?: false
            handled = (tapDetector?.onTouchEvent(ev) ?: false) || handled
            true
        }
    }

    private fun setZoom(ratio: Float) {
        val state = camera?.cameraInfo?.zoomState?.value ?: return
        camera?.cameraControl?.setZoomRatio(ratio.coerceIn(state.minZoomRatio, state.maxZoomRatio))
    }

    private fun resetZoom() = setZoom(1f)

    private fun focusAt(x: Float, y: Float) {
        val cam = camera ?: return
        val point = previewView.meteringPointFactory.createPoint(x, y)
        val action = FocusMeteringAction.Builder(
            point,
            FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE
        ).setAutoCancelDuration(3, TimeUnit.SECONDS).build()
        cam.cameraControl.startFocusAndMetering(action)
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun isMacroSupported(cam: Camera?): Boolean {
        return try {
            val c2 = Camera2CameraInfo.from(cam?.cameraInfo ?: return false)
            val afModes = c2.getCameraCharacteristic(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: intArrayOf()
            afModes.contains(CaptureRequest.CONTROL_AF_MODE_MACRO)
        } catch (_: Throwable) {
            false
        }
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun buildMacroStatus(): Map<String, Any?> {
        val cam = camera ?: return emptyMap()
        val c2 = try {
            Camera2CameraInfo.from(cam.cameraInfo)
        } catch (_: Throwable) {
            null
        }
        return mapOf(
            "requestedMacro" to macroEnabled,
            "macroSupported" to (macroSupported ?: isMacroSupported(cam)),
            "zoomRatio" to cam.cameraInfo.zoomState.value?.zoomRatio,
            "maxZoomRatio" to cam.cameraInfo.zoomState.value?.maxZoomRatio,
            "minZoomRatio" to cam.cameraInfo.zoomState.value?.minZoomRatio
        ) + (c2?.let {
            mapOf(
                "minFocusDistanceDiopters" to it.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
            )
        } ?: emptyMap())
    }

    override fun getView(): FrameLayout = linearLayout

    override fun dispose() {
        methodChannel.setMethodCallHandler(null)
        plugin?.removeListener(this)
        unbindOwnUseCases()
        try {
            if (::textScanner.isInitialized) {
                textScanner.close()
            }
        } catch (_: Throwable) {
        }
        cameraExecutor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "changeFlashMode" -> {
                call.argument<Int>("flashModeID")?.let { changeFlashMode(it) }
                result.success(true)
            }
            "getFlashMode" -> result.success(isTorchOn())
            "switchCamera" -> {
                call.argument<Int>("cameraID")?.let { switchCamera(it) }
                result.success(true)
            }
            "pauseCamera" -> pauseCamera(result)
            "resumeCamera" -> resumeCamera(result)
            "takePicture" -> takePicture(result)
            "setZoom" -> {
                call.argument<Double>("zoom")?.toFloat()?.let { setZoom(it) }
                result.success(true)
            }
            "resetZoom" -> {
                resetZoom()
                result.success(true)
            }
            "setMacro" -> {
                setMacro(call.argument<Boolean>("enabled") ?: false)
                result.success(true)
            }
            "setOcrRotation" -> {
                ocrRotationOverride = call.argument<Int>("degrees")
                result.success(true)
            }
            "clearOcrRotation" -> {
                ocrRotationOverride = null
                result.success(true)
            }
            "setShowTextRectangles" -> {
                // Stored for API parity with iOS; Android does not draw OCR
                // bounding boxes yet (no-op for rendering).
                showTextRectangles = call.argument<Boolean>("show") ?: false
                result.success(true)
            }
            "dispose" -> {
                dispose()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun switchCamera(cameraID: Int) {
        cameraSelector = if (cameraID == 0) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
        macroEnabled = false
        macroSupported = null
        setupCamera()
    }

    private fun resumeCamera(result: MethodChannel.Result?) {
        setupCamera()
        result?.success(true)
    }

    private fun pauseCamera(result: MethodChannel.Result?) {
        unbindOwnUseCases()
        result?.success(true)
    }

    private fun changeFlashMode(flashModeID: Int) {
        camera?.cameraControl?.enableTorch(flashModeID == 1)
    }

    private fun isTorchOn(): Boolean {
        return camera?.cameraInfo?.torchState?.value == TorchState.ON
    }

    private fun setMacro(enabled: Boolean) {
        macroEnabled = enabled
        setupCamera()
    }
}
