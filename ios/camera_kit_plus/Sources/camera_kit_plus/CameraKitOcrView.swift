import Flutter
import UIKit

import Foundation
import AVFoundation
import AudioToolbox
import Vision

class CameraOcrViewContainer: UIView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

@available(iOS 13.0, *)
class CameraKitOcrView: NSObject, FlutterPlatformView, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var _view: UIView
    var channel: FlutterMethodChannel
    let frame: CGRect
    //    var hasBarcodeReader:Bool!
    var imageSavePath:String!
    var isCameraVisible:Bool! = true
    /// Host pause must win over delayed session start.
    private var isSessionPaused = false
    var initCameraFinished:Bool! = false
    var isFillScale:Bool!
    var flashMode:AVCaptureDevice.FlashMode!
    var cameraPosition: AVCaptureDevice.Position! = .back
    var previewView : CameraOcrViewContainer!
    var videoDataOutput: AVCaptureVideoDataOutput!
    var videoDataOutputQueue: DispatchQueue!
    var photoOutput: AVCapturePhotoOutput?
    var previewLayer:AVCaptureVideoPreviewLayer!
    var captureDevice : AVCaptureDevice!
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera_kit_plus.ocr.sessionQueue") // Serial queue for session ops
    
    private var ocrReady = false
    private var isProcessingOcr = false
    /// Minimum gap between live OCR requests (~3/s).
    private var lastOcrTs: CFAbsoluteTime = 0
    private let ocrMinInterval: CFAbsoluteTime = 0.33
    /// Live Vision jobs: 0 and 1 = `.accurate`, 2 = `.fast`, then wrap.
    private var liveOcrCycleIndex = 0
    var flutterResultTakePicture:FlutterResult!
    var flutterResultOcr:FlutterResult!
    var orientation : UIImage.Orientation!
    private var isCapturing = false
    private var overlayView: UIView!
    private let overlayLayer = CAShapeLayer()
    private var lastFrameImageSize: CGSize = .zero //
    private var muteShutter: Bool = true
    private var prevAudioCategory: AVAudioSession.Category?
    private var prevAudioMode: AVAudioSession.Mode?
    private var prevAudioOptions: AVAudioSession.CategoryOptions = []
    private var didChangeAudioSession = false
    // New optional feature toggle
    var showTextRectangles: Bool = false
    /// When true, tap-to-focus and subject-area re-AF are enabled. CAF always runs.
    var focusRequired: Bool = true
    private var viewId: Int64 = 0

    /// 0:camera 1:barcodeScanner 2:ocrReader
    var usageMode:Int = 0

    // Zoom
    private var minZoomFactor: CGFloat = 1.0
    private var lastZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat {
        // Cap practical zoom to 8x to avoid ugly noise; raise if you want
        return min(self.captureDevice?.activeFormat.videoMaxZoomFactor ?? 1.0, 8.0)
    }

    // Forced OCR rotation (0..3 quarter turns)
    private var forcedQuarterTurns: Int = 0

    // ===== Macro =====
    private var isMacroEnabled: Bool = false

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger?
    ) {
        _view = UIView()
        self.frame = frame
        self.viewId = viewId
        self.channel = FlutterMethodChannel(
            name: "camera_kit_plus/view_\(viewId)",
            binaryMessenger: messenger!
        )

        super.init()
        self.flashMode = .off // default to safe value
        
        if let myArgs = args as? [String: Any] {
            if let showRects = myArgs["showTextRectangles"] as? Bool {
                self.showTextRectangles = showRects
            }
            if let focus = myArgs["focusRequired"] as? Bool {
                self.focusRequired = focus
            }
        }

        createNativeView(view: _view)
        setupCamera()
        channel.setMethodCallHandler(handle)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleOrientationChange),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleSubjectAreaDidChange),
                                               name: .AVCaptureDeviceSubjectAreaDidChange,
                                               object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        isSessionPaused = true
        if session.isRunning {
            session.stopRunning()
        }
    }

    func view() -> UIView {
        if previewView == nil {
            self.previewView = CameraOcrViewContainer(frame: frame)
            self.previewView.onLayoutSubviews = { [weak self] in
                self?.updatePreviewLayout()
            }
        }
        previewView.isUserInteractionEnabled = true
        attachZoomGesturesIfNeeded()
        if overlayView == nil {
            overlayView = UIView(frame: previewView.bounds)
            overlayView.backgroundColor = .clear
            overlayView.isUserInteractionEnabled = false
            overlayLayer.strokeColor = UIColor.systemYellow.cgColor
            overlayLayer.fillColor = UIColor.clear.cgColor
            overlayLayer.lineWidth = 2.0
            overlayLayer.lineJoin = .round
            overlayLayer.lineCap = .round
            overlayView.layer.addSublayer(overlayLayer)
            previewView.addSubview(overlayView)
        }
        return previewView
    }
    
    private func updatePreviewLayout() {
        guard let pl = previewLayer else { return }
        pl.frame = previewView.bounds
        updateVideoOrientation()
        layoutOverlaysToPreviewBounds()
    }

    private func updateVideoOrientation() {
        guard let conn = previewLayer?.connection, conn.isVideoOrientationSupported else { return }
        switch interfaceOrientation() {
        case .landscapeLeft:
            conn.videoOrientation = .landscapeLeft
        case .landscapeRight:
            conn.videoOrientation = .landscapeRight
        case .portraitUpsideDown:
            conn.videoOrientation = .portraitUpsideDown
        default:
            conn.videoOrientation = .portrait
        }
    }
    
    @objc private func handleOrientationChange() {
        DispatchQueue.main.async {
            self.updatePreviewLayout()
        }
    }
    
    private func layoutOverlaysToPreviewBounds() {
        guard overlayView != nil else { return }
        overlayView.frame = previewView.bounds
        overlayLayer.frame = overlayView.bounds
    }

    func createNativeView(view _view: UIView) {
        _view.backgroundColor = .black
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments
        let myArgs = args as? [String: Any]
        switch call.method {
        // Plugin channel owns getCameraPermission; view-level retained as documented no-op redirect.
        case "getCameraPermission":
            self.getCameraPermission(flutterResult: result)

        case "changeFlashMode":
            let mode = (myArgs?["flashModeID"] as? Int) ?? 0
            changeFlashMode(modeID: mode, result: result)

        case "getFlashMode":
            result(self.captureDevice?.isTorchActive ?? false)

        case "switchCamera":
            let cameraID = (myArgs?["cameraID"] as? Int) ?? 0
            self.switchCamera(cameraID: cameraID, result: result)

        case "changeCameraVisibility":
            // Legacy; prefer pauseCamera / resumeCamera.
            let visibility = (myArgs?["visibility"] as? Bool) ?? true
            self.changeCameraVisibility(visibility: visibility)
            result(true)

        case "pauseCamera":
            self.pauseCamera(); result(true)

        case "resumeCamera":
            self.resumeCamera(); result(true)

        case "takePicture":
            let path = (myArgs?["path"] as? String) ?? ""
            self.takePicture(path:path,flutterResult: result)

        case "dispose":
            self.disposeNative()
            result(true)

        case "setZoom":
            if let z = myArgs?["zoom"] as? Double {
                self.setZoom(factor: CGFloat(z), animated: true)
                result(true)
            } else {
                result(FlutterError(code: "bad_args", message: "zoom (Double) required", details: nil))
            }

        case "resetZoom":
            self.setZoom(factor: 1.0, animated: true)
            result(true)

        case "setOcrRotation":
            let deg = (myArgs?["degrees"] as? Int) ?? 0
            let turns = ((deg / 90) % 4 + 4) % 4
            self.forcedQuarterTurns = turns
            result(true)

        case "clearOcrRotation":
            self.forcedQuarterTurns = 0
            result(true)

        case "setMacro":
            let enabled = (myArgs?["enabled"] as? Bool) ?? false
            self.setMacro(enabled: enabled)
            result(true)
            
        case "setShowTextRectangles":
            let show = (myArgs?["show"] as? Bool) ?? false
            self.showTextRectangles = show
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func getCameraPermission(flutterResult:  @escaping FlutterResult) {
        if AVCaptureDevice.authorizationStatus(for: .video) ==  .authorized {
            flutterResult(true as Bool)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                AVCaptureDevice.requestAccess(for: .video, completionHandler: { (granted: Bool) in
                    DispatchQueue.main.async {
                        flutterResult(granted)
                    }
                })
            }
        }
    }

    /// Stops capture, tears down session I/O, and clears the method channel.
    private func disposeNative() {
        isSessionPaused = true
        stopCamera()
        liveOcrCycleIndex = 0
        isProcessingOcr = false
        sessionQueue.async {
            self.session.beginConfiguration()
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }
            self.session.commitConfiguration()
            self.captureDevice = nil
        }
        channel.setMethodCallHandler(nil)
    }

    func setupCamera(){
        self.usageMode = 2
        self.isFillScale = true
        self.cameraPosition = .back
        self.flashMode = .off
        ocrReady = true
        self.setupAVCapture()
    }

    func initCamera( flashMode: Int, fill: Bool, barcodeTypeID: Int, cameraID: Int, modeID: Int) {
        print("Usage Mode set to "+String(modeID))
        self.usageMode = modeID
        self.isFillScale = fill
        self.cameraPosition = cameraID == 0 ? .back : .front
        ocrReady = true
        self.setupAVCapture()
    }

    // Prefer wide / multi-camera for MRZ OCR; ultra-wide only as last resort (macro path switches separately).
    @available(iOS 13.0, *)
    private func bestBackCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInWideAngleCamera,
                .builtInUltraWideCamera
            ],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first
    }

    /// Switches between front and back cameras while keeping the OCR session alive.
    func switchCamera(cameraID: Int, result: @escaping FlutterResult) {
        cameraPosition = cameraID == 0 ? .back : .front
        sessionQueue.async {
            self.session.beginConfiguration()
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            let device: AVCaptureDevice?
            if self.cameraPosition == .back {
                device = self.bestBackCamera()
            } else {
                device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            }
            guard let captureDevice = device,
                  let deviceInput = try? AVCaptureDeviceInput(device: captureDevice) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { result(false) }
                return
            }
            self.captureDevice = captureDevice
            if self.session.canAddInput(deviceInput) {
                self.session.addInput(deviceInput)
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async { result(true) }
        }
    }

    @available(iOS 13.0, *)
    func setupAVCapture(){
        // 720p live OCR; frames cycle 2× `.accurate` then 1× `.fast`. Still-photo stays `.accurate`.
        session.sessionPreset = AVCaptureSession.Preset.hd1280x720

        // pick best back camera
            if cameraPosition == .back, let dev = bestBackCamera() {
                captureDevice = dev
            } else if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition) {
                captureDevice = dev
            } else {
                return
            }


        beginSession()
        // changeFlashMode()
    }

    func beginSession(isFirst: Bool = true){
        var deviceInput: AVCaptureDeviceInput!
        liveOcrCycleIndex = 0
        isProcessingOcr = false

        do {
            // Clear prior inputs/outputs so resume/re-init cannot duplicate them.
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }

            deviceInput = try AVCaptureDeviceInput(device: captureDevice)
            guard deviceInput != nil else {
                print("error: cant get deviceInput")
                session.commitConfiguration()
                return
            }

            if self.session.canAddInput(deviceInput){
                self.session.addInput(deviceInput)
            }
            lastZoomFactor = 1.0
            if let pConn = photoOutput?.connection(with: .video) {
                pConn.isEnabled = true
            }

            orientation = imageOrientation(fromDevicePosition: cameraPosition)

            // OCR video output
            videoDataOutput = AVCaptureVideoDataOutput()
            videoDataOutput.alwaysDiscardsLateVideoFrames = true

            videoDataOutputQueue = DispatchQueue(label: "VideoDataOutputQueue")
            videoDataOutput.setSampleBufferDelegate(self, queue:self.videoDataOutputQueue)
            if session.canAddOutput(videoDataOutput!){
                session.addOutput(videoDataOutput)
            }
            videoDataOutput.connection(with: .video)?.isEnabled = true

            AudioServicesDisposeSystemSoundID(1108)

            // Photo output — skip high-res stills; live OCR does not need them.
            photoOutput = AVCapturePhotoOutput()
            photoOutput?.isHighResolutionCaptureEnabled = false
            photoOutput?.setPreparedPhotoSettingsArray(
                [AVCapturePhotoSettings(format: [AVVideoCodecKey : AVVideoCodecJPEG])],
                completionHandler: nil
            )
            if session.canAddOutput(photoOutput!){
                session.addOutput(photoOutput!)
            }

            applyFocusConfiguration()
            if let device = captureDevice {
                do {
                    try device.lockForConfiguration()
                    let fps = CMTime(value: 1, timescale: 15)
                    if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameDuration <= fps && $0.maxFrameDuration >= fps
                    }) {
                        device.activeVideoMinFrameDuration = fps
                        device.activeVideoMaxFrameDuration = fps
                    }
                    device.unlockForConfiguration()
                } catch {
                    print("OCR frame-rate config error: \(error)")
                }
            }

            session.commitConfiguration()

            // Preview
            previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
            previewLayer.videoGravity = self.isFillScale == true ? .resizeAspectFill : .resizeAspect

            startSession(isFirst: isFirst)

        } catch let error as NSError {
            deviceInput = nil
            session.commitConfiguration()
            print("error: \(error.localizedDescription)")
        }
    }

    func startSession(isFirst: Bool) {
        // Weak self so a zero-size retry cannot keep this view alive after
        // Flutter tears the platform view down (fast modal close).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isSessionPaused else { return }
            // Ensure view is created
            if self.previewView == nil {
                 // Should not happen if view() was called, but safety check
                 _ = self.view()
            }
            let rootLayer :CALayer = self.previewView.layer
            rootLayer.masksToBounds = true
            
            // If view has no size yet, retry later
            if(rootLayer.bounds.size.width != 0 && rootLayer.bounds.size.width != 0){
                self.previewLayer.frame = rootLayer.bounds
                self.updateVideoOrientation() // Set initial orientation correctly
                self.layoutOverlaysToPreviewBounds()

                // Check if already added
                if self.previewLayer.superlayer == nil {
                    rootLayer.addSublayer(self.previewLayer)
                    
                    // Add overlay view on top of preview layer
                    if self.overlayView != nil {
                        self.previewView.bringSubviewToFront(self.overlayView)
                    }
                }
                
                self.sessionQueue.async { [weak self] in
                    guard let self, !self.isSessionPaused else { return }
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    if isFirst == true {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            self?.initCameraFinished = true
                        }
                    }
                }
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startSession(isFirst: isFirst)
                }
            }
        }
    }

    /// Sets continuous torch for preview, and updates the still-photo flash mode to match.
    /// Pass .off / .on / .auto (AVCaptureDevice.TorchMode)
    func setFlashMode(mode: AVCaptureDevice.TorchMode) {
        // 1) Keep your photo flash mode in sync for still captures
        switch mode {
        case .on:   self.flashMode = .on
        case .auto: self.flashMode = .auto
        default:    self.flashMode = .off
        }

        // 2) Apply torch for the live preview (rear camera only)
        guard let device = self.captureDevice,
              device.hasTorch,
              self.cameraPosition == .back
        else {
            // Front camera or no torch: nothing else to do
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // If requested mode isn’t supported, fall back gracefully
            guard device.isTorchModeSupported(mode) else {
                device.torchMode = .off
                return
            }

            switch mode {
            case .on:
                // Moderate torch — max level overheats during live OCR.
                let level = min(0.5, AVCaptureDevice.maxAvailableTorchLevel)
                try? device.setTorchModeOn(level: level)

            case .auto:
                device.torchMode = .auto
            case .off:
                device.torchMode = .off
            @unknown default:
                device.torchMode = .off
            }

        } catch {
            print("Torch config error: \(error)")
        }
    }


    func changeFlashMode(modeID: Int,result:  @escaping FlutterResult){
        setFlashMode(mode: (modeID == 2) ?(.auto):(modeID == 1 ? (.on) : (.off)))
        result(true)
    }

    func pauseCamera() {
        isSessionPaused = true
        self.stopCamera()
        self.isCameraVisible = false
    }

    func resumeCamera() {
        isSessionPaused = false
        self.isCameraVisible = true
        sessionQueue.async {
            guard !self.isSessionPaused else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stopCamera(){
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func changeCameraVisibility(visibility:Bool){
        if visibility == true {
            if self.isCameraVisible == false {
                self.resumeCamera() // Reuse
            }
        } else {
            if self.isCameraVisible == true {
                self.pauseCamera() // Reuse
            }
        }
    }

    // -------------------------
    // UPDATED takePicture (iOS 13+, modern delegate, connection-ready)
    // -------------------------
    func takePicture(path :String, flutterResult:  @escaping FlutterResult){
        guard let photoOutput = self.photoOutput else {
            flutterResult(FlutterError(code: "-100", message: "Photo output not configured", details: nil))
            return
        }
        guard let device = self.captureDevice else {
            flutterResult(FlutterError(code: "-104", message: "Camera device not ready", details: nil))
            return
        }
        // guard self.initCameraFinished == true else { ... } // maybe relax if running?
        
        guard !isCapturing else {
            flutterResult(FlutterError(code: "-106", message: "Capture in progress", details: nil))
            return
        }
        isCapturing = true

        self.imageSavePath = path
        self.flutterResultTakePicture = flutterResult

        // iOS 13+: use modern settings with explicit format
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        if photoOutput.isHighResolutionCaptureEnabled {
            settings.isHighResolutionPhotoEnabled = true
        }

        // Apply still-photo flash mode if supported
        let desiredFlash = self.flashMode ?? .off
        if device.hasFlash, photoOutput.supportedFlashModes.contains(desiredFlash) {
            settings.flashMode = desiredFlash
        }

        // Ensure the session is running
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
        
        self.beginSilentAudioSessionIfNeeded()


        // Wait for photo connection to be active (prevents "No active and enabled video connection")
        self.waitForActivePhotoConnection { conn in
            guard let conn = conn else {
                self.isCapturing = false
                self.endSilentAudioSessionIfNeeded()   // <— restore

                flutterResult(FlutterError(code: "-107",
                                           message: "No active/enabled video connection",
                                           details: "Waited for connection but it never became active"))
                return
            }

            // Sync orientation/mirroring to preview
            if let prev = self.previewLayer?.connection, prev.isVideoOrientationSupported {
                conn.videoOrientation = prev.videoOrientation
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = (self.cameraPosition == .front)
            }

            DispatchQueue.main.async {
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // Modern photo delegate (iOS 13+)
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        defer {
            isCapturing = false
            self.endSilentAudioSessionIfNeeded()   // <— restore here
        }

        if let error = error {
            self.flutterResultTakePicture?(FlutterError(code: "-101", message: error.localizedDescription, details: nil))
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            self.flutterResultTakePicture?(FlutterError(code: "-102", message: "No photo data", details: nil))
            return
        }

        _ = self.saveImage(image: image)

        // Optional: keep current zoom stable after capture
        if let device = self.captureDevice {
            do {
                try device.lockForConfiguration()
                let clamped = max(1.0, min(device.videoZoomFactor, device.activeFormat.videoMaxZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch { /* ignore */ }
        }
    }
    
    // Save to the provided path (or Documents/pic.jpg) and return the path via FlutterResult
    func saveImage(image: UIImage) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.95) ?? image.pngData() else {
            self.flutterResultTakePicture?(FlutterError(code: "-103a", message: "Could not encode image", details: nil))
            return false
        }
        let url: URL = {
            let dir = (try? FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true))
                      ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return dir.appendingPathComponent("pic.jpg")
        }()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            self.flutterResultTakePicture?(url.path)
            print(url.path)
            return true
        } catch {
            print("saveImage error: \(error)")
            self.flutterResultTakePicture?(FlutterError(code: "-103", message: error.localizedDescription, details: nil))
            return false
        }
    }

    private func waitForActivePhotoConnection(
        maxAttempts: Int = 20,
        delayMs: Int = 50,
        _ ready: @escaping (AVCaptureConnection?) -> Void
    ) {
        var attempts = 0
        func tick() {
            attempts += 1
            guard let p = self.photoOutput,
                  let conn = p.connection(with: .video) else {
                if attempts >= maxAttempts { ready(nil); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { tick() }
                return
            }
            if conn.isEnabled && conn.isActive {
                ready(conn)
            } else if attempts >= maxAttempts {
                ready(nil)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { tick() }
            }
        }
        tick()
    }

    private func invokeOnMain(_ method: String, arguments: Any?) {
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod(method, arguments: arguments)
        }
    }

    func onBarcodeRead(barcode: String) {
        invokeOnMain("onBarcodeRead", arguments: barcode)
    }

    func onTextRead(text: String, values: [LineModel], path: String?, orientation: Int?) {
        let data = OcrData(text: text, path: path, orientation: orientation, lines: values)
        do {
            let jsonData = try JSONEncoder().encode(data)
            let json = String(data: jsonData, encoding: .utf8)
            invokeOnMain("onTextRead", arguments: json)
        } catch {
            print("JSON encode error: \(error)")
        }
    }

    func textRead(text: String, values: [LineModel], path: String?, orientation: Int?) {
        let data = OcrData(text: text, path: path, orientation: orientation, lines: values)
        let jsonEncoder = JSONEncoder()
        do {
            let jsonData = try jsonEncoder.encode(data)
            let json = String(data: jsonData, encoding: .utf8)
            flutterResultOcr?(json)
        } catch {
            flutterResultOcr?(FlutterError(code:"-200", message:"JSON encode error", details:error.localizedDescription))
        }
    }

    // -------------------------
    // Still image OCR (Apple Vision, accurate)
    // -------------------------
    func processImageFromPath(path:String,flutterResult:  @escaping FlutterResult){
        let fileURL = URL(fileURLWithPath: path)
        do {
            self.flutterResultOcr = flutterResult
            let imageData = try Data(contentsOf: fileURL)
            guard let image = UIImage(data: imageData), let cgImage = image.cgImage else { return }
            let uiOrientation = rotate(image.imageOrientation, turns: forcedQuarterTurns)
            let cgOrientation = Self.cgImageOrientation(from: uiOrientation)
            recognizeText(
                cgImage: cgImage,
                orientation: cgOrientation,
                recognitionLevel: .accurate,
                bufferSize: CGSize(width: cgImage.width, height: cgImage.height)
            ) { text, lines in
                if text.isEmpty {
                    self.textRead(text: "", values: [], path: path, orientation: nil)
                } else {
                    self.textRead(text: text, values: lines, path: path, orientation: uiOrientation.rawValue)
                }
            }
        } catch {
            print("Error loading image : \(error)")
        }
    }

    // -------------------------
    // Zoom gestures
    // -------------------------
    private func attachZoomGesturesIfNeeded() {
        if let grs = previewView.gestureRecognizers, grs.isEmpty == false { return }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        previewView.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapResetZoom))
        doubleTap.numberOfTapsRequired = 2
        previewView.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        tap.numberOfTapsRequired = 1
        tap.require(toFail: doubleTap)
        previewView.addGestureRecognizer(tap)
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        guard let device = self.captureDevice else { return }

        switch pinch.state {
        case .began:
            lastZoomFactor = device.videoZoomFactor

        case .changed:
            var newFactor = lastZoomFactor * pinch.scale
            newFactor = max(minZoomFactor, min(newFactor, maxZoomFactor))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = newFactor
                device.unlockForConfiguration()
            } catch {
                print("Zoom lock error: \(error)")
            }

        case .ended, .cancelled, .failed:
            let target = max(minZoomFactor, min(device.videoZoomFactor, maxZoomFactor))
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: target, withRate: 8.0)
                  invokeOnMain("onZoomChanged", arguments: target)
                device.unlockForConfiguration()
            } catch {
                print("Zoom end error: \(error)")
            }
            lastZoomFactor = target

        default: break
        }
    }

    @objc private func handleDoubleTapResetZoom() {
        setZoom(factor: 1.0, animated: true)
    }

    @objc private func handleTapToFocus(_ tap: UITapGestureRecognizer) {
        guard focusRequired, let device = captureDevice, previewLayer != nil else { return }
        let viewPoint = tap.location(in: previewView)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        focus(at: devicePoint, thenLock: true)
    }

    @objc private func handleSubjectAreaDidChange() {
        guard focusRequired else { return }
        focus(at: CGPoint(x: 0.5, y: 0.5), thenLock: false)
    }

    /// Focus at a device-space point. After a tap, lock on that POI; otherwise resume CAF.
    private func focus(at devicePoint: CGPoint, thenLock: Bool) {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
            }
            if thenLock, device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            } else {
                applyContinuousAutoFocus(on: device)
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            print("focus error: \(error)")
        }
    }

    private func applyContinuousAutoFocus(on device: AVCaptureDevice) {
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        } else if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }
    }

    private func setZoom(factor: CGFloat, animated: Bool = true) {
        guard let device = self.captureDevice else { return }
        let clamped = max(minZoomFactor, min(factor, maxZoomFactor))
        do {
            try device.lockForConfiguration()
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 8.0)
            } else {
                device.videoZoomFactor = clamped
            }

            invokeOnMain("onZoomChanged", arguments: clamped)

            device.unlockForConfiguration()
            lastZoomFactor = clamped
        } catch {

            print("setZoom error: \(error)")
        }
    }

    // -------------------------
    // Orientation helpers for forced OCR rotation
    // -------------------------
    private func rotate90CW(_ o: UIImage.Orientation) -> UIImage.Orientation {
        switch o {
        case .up: return .right
        case .right: return .down
        case .down: return .left
        case .left: return .up
        case .upMirrored: return .rightMirrored
        case .rightMirrored: return .downMirrored
        case .downMirrored: return .leftMirrored
        case .leftMirrored: return .upMirrored
        @unknown default: return o
        }
    }

    private func rotate(_ o: UIImage.Orientation, turns: Int) -> UIImage.Orientation {
        let t = ((turns % 4) + 4) % 4
        var cur = o
        for _ in 0..<t { cur = rotate90CW(cur) }
        return cur
    }
    
    // MARK: - Orientation helpers

    private func interfaceOrientation() -> UIInterfaceOrientation {
        if #available(iOS 13.0, *) {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                return scene.interfaceOrientation
            }
        } else {
            // Fallback on earlier versions
        }
        return UIApplication.shared.statusBarOrientation
    }

    private func currentUIOrientation() -> UIDeviceOrientation {
        let io = interfaceOrientation()
        switch io {
        case .portrait:             return .portrait
        case .portraitUpsideDown:   return .portraitUpsideDown
        case .landscapeLeft:        return .landscapeRight
        case .landscapeRight:       return .landscapeLeft
        default:                    return .portrait
        }
    }

    public func imageOrientation(
        fromDevicePosition devicePosition: AVCaptureDevice.Position = .back
    ) -> UIImage.Orientation {
        // Force use of currentUIOrientation (derived from interfaceOrientation)
        // to match preview layer logic.
        let deviceOrientation = currentUIOrientation()
        
        switch deviceOrientation {
        case .portrait:
            return devicePosition == .front ? .leftMirrored : .right
        case .landscapeLeft:
            return devicePosition == .front ? .downMirrored : .up
        case .portraitUpsideDown:
            return devicePosition == .front ? .rightMirrored : .left
        case .landscapeRight:
            return devicePosition == .front ? .upMirrored : .down
        case .faceDown, .faceUp, .unknown:
            return .up
        @unknown default:
            return .up
        }
    }

    // ===== Macro helpers =====
    @available(iOS 13.0, *)
    private func setMacro(enabled: Bool) {
        isMacroEnabled = enabled
        applyFocusConfiguration()
        // Optional: small zoom to help framing when close
        
        if(enabled){
            switchBackCamera(preferUltraWide: enabled)
        }else{
            switchBackCamera(preferUltraWide: false)
        }
//        if enabled { setZoom(factor: max(1.0, min(1.3, maxZoomFactor)), animated: true) }
//        if !enabled { setZoom(factor: max(1.0, min(1.0, maxZoomFactor)), animated: true) }
    }

    private func applyFocusConfiguration() {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()

            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            // CAF always runs so the preview is usable. focusRequired only gates
            // tap-to-focus / subject-area re-AF — never lock the lens at infinity.
            device.isSubjectAreaChangeMonitoringEnabled = focusRequired

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }

            if isMacroEnabled, device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            } else if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }

            applyContinuousAutoFocus(on: device)

            invokeOnMain("onMacroChanged", arguments: self.buildMacroStatus())

            device.unlockForConfiguration()
        } catch {
            print("applyFocusConfiguration error: \(error)")
        }
    }
    
    private func buildMacroStatus() -> [String: Any] {
        print("buildMacroStatus")
        var status: [String: Any] = [
            "requestedMacro": isMacroEnabled as Any
        ]
        guard let d = captureDevice else { return status }

        status["supportsNearRestriction"] = d.isAutoFocusRangeRestrictionSupported
        if d.isAutoFocusRangeRestrictionSupported {
            status["autoFocusRangeRestriction"] = (d.autoFocusRangeRestriction == .near ? "near" :
                                                   d.autoFocusRangeRestriction == .far  ? "far"  : "none")
        }
        status["focusMode"] = {
            switch d.focusMode {
            case .locked: return "locked"
            case .autoFocus: return "autoFocus"
            case .continuousAutoFocus: return "continuousAutoFocus"
            @unknown default: return "unknown"
            }
        }()
        status["smoothAutoFocus"] = d.isSmoothAutoFocusSupported ? d.isSmoothAutoFocusEnabled : false
        status["subjectAreaMonitoring"] = d.isSubjectAreaChangeMonitoringEnabled
        status["focusPOISupported"] = d.isFocusPointOfInterestSupported
        if d.isFocusPointOfInterestSupported {
            status["focusPOI"] = ["x": d.focusPointOfInterest.x, "y": d.focusPointOfInterest.y]
        }
        status["zoomFactor"] = d.videoZoomFactor
        status["maxZoomFactor"] = d.activeFormat.videoMaxZoomFactor
        status["deviceType"] = d.deviceType.rawValue
        if #available(iOS 13.0, *) {
            status["fieldOfView"] = d.activeFormat.videoFieldOfView
        }
        // Lens position is read-only; useful to see we're near the close end (≈1.0)
        if d.isFocusModeSupported(.continuousAutoFocus) || d.isFocusModeSupported(.autoFocus) || d.isFocusModeSupported(.locked) {
            status["lensPosition"] = d.lensPosition  // 0 = far, 1 = near (approximate)
        }
        print(status)
        return status
    }
    
    /// Switches the active back camera device. If `preferUltraWide` is true,
    /// it picks Ultra Wide (for close focus). Otherwise it uses the virtual
    /// multi-camera if available (triple/dual-wide), falling back to Wide.
    @available(iOS 13.0, *)
    private func switchBackCamera(preferUltraWide: Bool) {
        guard cameraPosition == .back else { return }

        // Choose target device
        let target: AVCaptureDevice? = {
            if preferUltraWide {
                // Macro: Ultra Wide focuses closest (on supported iPhones)
                return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)!
            } else {
                // Normal: match bestBackCamera() — triple → dual-wide → wide → ultra-wide last.
                return AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            }
        }()

        guard let newDevice = target else { return }

        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // Remove ONLY existing video device inputs
            for input in session.inputs {
                if let dInput = input as? AVCaptureDeviceInput, dInput.device.hasMediaType(.video) {
                    session.removeInput(dInput)
                }
            }

            if session.canAddInput(newInput) {
                session.addInput(newInput)
                self.captureDevice = newDevice
            }

            // Re-apply focus / macro bias on the new device
            applyFocusConfiguration()

            // Keep your existing outputs; they remain attached to the session

        } catch {
            print("switchBackCamera error: \(error)")
        }
    }
    
    /// Map a point from image space (width x height) into previewView's coordinates,
    /// taking .resizeAspectFill into account. If `turns` != 0, rotates the image point
    /// by 90° * turns around the image center before mapping.
    private func previewPoint(fromImagePoint p: CGPoint,
                              imageSize: CGSize,
                              turns: Int = 0) -> CGPoint
    {
        var pt = p
        var imgW = imageSize.width
        var imgH = imageSize.height

        // Apply 90° steps rotation in image space if needed
        let t = ((turns % 4) + 4) % 4
        if t != 0 {
            // rotate about image center
            let cx = imgW * 0.5, cy = imgH * 0.5
            let x = p.x - cx, y = p.y - cy
            var xr = x, yr = y
            // 90° CW per turn
            for _ in 0..<t {
                let nx =  y
                let ny = -x
                xr = nx; yr = ny
                // swap width/height for each quarter-turn
                swap(&imgW, &imgH)
            }
            pt = CGPoint(x: xr + imgW*0.5, y: yr + imgH*0.5)
        }

        // Aspect-fill scale & offset to previewView
        let pv = previewView.bounds.size
        let s = max(pv.width / imgW, pv.height / imgH)
        let drawW = imgW * s
        let drawH = imgH * s
        let ox = (pv.width  - drawW) * 0.5
        let oy = (pv.height - drawH) * 0.5

        return CGPoint(x: ox + pt.x * s, y: oy + pt.y * s)
    }
    
    private func drawOverlays(for lines: [LineModel],
                              imageSize: CGSize,
                              turns: Int)
    {
        let path = UIBezierPath()

        for line in lines {
            guard line.cornerPoints.count >= 4 else { continue }

            let pts = line.cornerPoints.map { cp -> CGPoint in
                let ip = CGPoint(x: cp.x, y: cp.y)
                return self.previewPointUsingPreviewLayer(fromImagePoint: ip,
                                                          imageSize: imageSize,
                                                          turns: turns)
            }

            let quad = UIBezierPath()
            quad.move(to: pts[0])
            quad.addLine(to: pts[1])
            quad.addLine(to: pts[2])
            quad.addLine(to: pts[3])
            quad.close()
            path.append(quad)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(false)
        CATransaction.setAnimationDuration(0.12)
        overlayLayer.path = path.cgPath
        CATransaction.commit()
    }

    
    /// Convert an image-space pixel point (x in [0..imageW], y in [0..imageH])
    /// to a point in the previewView using previewLayer's converter.
    /// This handles .resizeAspectFill cropping, mirroring and orientation.
    private func previewPointUsingPreviewLayer(fromImagePoint p: CGPoint,
                                               imageSize: CGSize,
                                               turns: Int = 0) -> CGPoint
    {
        // Apply 90° CW rotations in image space if you use forcedQuarterTurns
        var pt = p
        var w = imageSize.width
        var h = imageSize.height
        let t = ((turns % 4) + 4) % 4
        if t != 0 {
            // rotate around image center by 90° CW per turn
            let cx = w * 0.5, cy = h * 0.5
            var x = p.x - cx, y = p.y - cy
            for _ in 0..<t {
                let nx =  y
                let ny = -x
                x = nx; y = ny
                swap(&w, &h) // width/height swap each quarter turn
            }
            pt = CGPoint(x: x + w*0.5, y: y + h*0.5)
        }

        // Normalize to [0,1] in the *capture device* space
        let norm = CGPoint(x: pt.x / w, y: pt.y / h)

        // Ask the preview layer to transform to layer space (handles aspectFill + mirroring)
        guard let pv = self.previewLayer else { return .zero }
        return pv.layerPointConverted(fromCaptureDevicePoint: norm)
    }

    
    private func clearOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        CATransaction.setAnimationDuration(0.08)
        overlayLayer.path = nil
        CATransaction.commit()
    }
    
    public func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard ocrReady, !isProcessingOcr else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastOcrTs >= ocrMinInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let bufferW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let bufferH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let bufferSize = CGSize(width: bufferW, height: bufferH)

        let base = imageOrientation(fromDevicePosition: cameraPosition)
        let uiOrientation = rotate(base, turns: forcedQuarterTurns)
        let cgOrientation = Self.cgImageOrientation(from: uiOrientation)
        lastFrameImageSize = Self.orientedSize(for: bufferSize, orientation: cgOrientation)

        lastOcrTs = now
        isProcessingOcr = true
        // Two accurate votes first so the first frames are usable, then one cheap tracker frame.
        let recognitionLevel: VNRequestTextRecognitionLevel =
            (liveOcrCycleIndex % 3 == 2) ? .fast : .accurate
        liveOcrCycleIndex += 1
        recognizeText(
            pixelBuffer: pixelBuffer,
            orientation: cgOrientation,
            recognitionLevel: recognitionLevel,
            bufferSize: bufferSize,
            regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        ) { [weak self] text, lines in
            guard let self = self else { return }
            self.isProcessingOcr = false

            let imgSize = self.lastFrameImageSize
            DispatchQueue.main.async {
                if !text.isEmpty && imgSize != .zero {
                    if self.showTextRectangles {
                        // Coordinates already match oriented image space.
                        self.drawOverlays(for: lines, imageSize: imgSize, turns: 0)
                    } else {
                        self.clearOverlays()
                    }
                } else {
                    self.clearOverlays()
                }
            }

            if !text.isEmpty {
                self.onTextRead(text: text, values: lines, path: "", orientation: uiOrientation.rawValue)
            }
            // Skip empty frames — avoid spamming Dart/ocr_mrz every sample buffer.
        }
    }

    // MARK: - Apple Vision OCR

    private func recognizeText(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        recognitionLevel: VNRequestTextRecognitionLevel,
        bufferSize: CGSize,
        regionOfInterest: CGRect? = nil,
        completion: @escaping (_ text: String, _ lines: [LineModel]) -> Void
    ) {
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                print("Vision OCR error: \(error)")
                completion("", [])
                return
            }
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let orientedSize = Self.orientedSize(for: bufferSize, orientation: orientation)
            let (text, lines) = Self.mapObservations(observations, imageSize: orientedSize)
            completion(text, lines)
        }
        request.recognitionLevel = recognitionLevel
        // MRZ/OCR-B is Latin; language correction hurts machine-readable strings.
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        if let roi = regionOfInterest {
            request.regionOfInterest = roi
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                print("Vision OCR perform error: \(error)")
                completion("", [])
            }
        }
    }

    private func recognizeText(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        recognitionLevel: VNRequestTextRecognitionLevel,
        bufferSize: CGSize,
        completion: @escaping (_ text: String, _ lines: [LineModel]) -> Void
    ) {
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                print("Vision OCR error: \(error)")
                completion("", [])
                return
            }
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let orientedSize = Self.orientedSize(for: bufferSize, orientation: orientation)
            let (text, lines) = Self.mapObservations(observations, imageSize: orientedSize)
            completion(text, lines)
        }
        request.recognitionLevel = recognitionLevel
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                print("Vision OCR perform error: \(error)")
                completion("", [])
            }
        }
    }

    private static func mapObservations(
        _ observations: [VNRecognizedTextObservation],
        imageSize: CGSize
    ) -> (String, [LineModel]) {
        var lines: [LineModel] = []
        var texts: [String] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = LineModel()
            line.text = candidate.string
            line.cornerPoints = cornerPoints(from: observation.boundingBox, imageSize: imageSize)
            lines.append(line)
            texts.append(candidate.string)
        }
        return (texts.joined(separator: "\n"), lines)
    }

    /// Vision bounding boxes are normalized with origin at bottom-left.
    /// Convert to image-pixel corner points (top-left origin), matching prior ML Kit shape.
    private static func cornerPoints(from box: CGRect, imageSize: CGSize) -> [CornerPointModel] {
        let w = imageSize.width
        let h = imageSize.height
        let topLeft = CGPoint(x: box.minX * w, y: (1 - box.maxY) * h)
        let topRight = CGPoint(x: box.maxX * w, y: (1 - box.maxY) * h)
        let bottomRight = CGPoint(x: box.maxX * w, y: (1 - box.minY) * h)
        let bottomLeft = CGPoint(x: box.minX * w, y: (1 - box.minY) * h)
        return [
            CornerPointModel(x: Double(topLeft.x), y: Double(topLeft.y)),
            CornerPointModel(x: Double(topRight.x), y: Double(topRight.y)),
            CornerPointModel(x: Double(bottomRight.x), y: Double(bottomRight.y)),
            CornerPointModel(x: Double(bottomLeft.x), y: Double(bottomLeft.y))
        ]
    }

    private static func cgImageOrientation(from ui: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch ui {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private static func orientedSize(for bufferSize: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: bufferSize.height, height: bufferSize.width)
        default:
            return bufferSize
        }
    }

    // ======== SOUND EFFECT (UPDATED) ========
    // Stronger shutter suppression using a temporary .record session.
    // Note: On devices sold in JP/KR, iOS forces shutter sound.

    private func beginSilentAudioSessionIfNeeded() {
        guard muteShutter else { return }
        let audio = AVAudioSession.sharedInstance()

        // Save previous state to restore later
        prevAudioCategory = audio.category
        prevAudioMode = audio.mode
        prevAudioOptions = audio.categoryOptions

        do {
            // .record reliably suppresses system sounds (incl. shutter) while active
            try audio.setCategory(.record, mode: .default, options: [])
            try audio.setActive(true, options: [])
            didChangeAudioSession = true
        } catch {
            print("AudioSession begin (mute shutter) error: \(error)")
            didChangeAudioSession = false
        }
    }

    private func endSilentAudioSessionIfNeeded() {
        guard didChangeAudioSession else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            // Deactivate our temporary session first
            try audio.setActive(false, options: [.notifyOthersOnDeactivation])

            // Restore previous category/mode/options if we had them
            if let cat = prevAudioCategory, let mode = prevAudioMode {
                try audio.setCategory(cat, mode: mode, options: prevAudioOptions)
                try audio.setActive(true, options: [])
            }
        } catch {
            print("AudioSession restore error: \(error)")
        }
        didChangeAudioSession = false
    }
    // =======================================

}
