//
//  CameraKitPlusView.swift
//  camera_kit_plus
//
//  Full version with Vision fallback, ROI, tuning, and all original features retained.
//
import Flutter
import UIKit
import Foundation
import AVFoundation
import Vision
import CoreGraphics
import AudioToolbox

class CameraContainerView: UIView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

@available(iOS 13.0, *)
class CameraKitPlusView: NSObject,
    FlutterPlatformView,
    AVCaptureMetadataOutputObjectsDelegate,
    AVCapturePhotoCaptureDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    // MARK: - UI / Session
    private var _view: CameraContainerView
    var captureSession = AVCaptureSession()
    var captureDevice: AVCaptureDevice!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutputRef: AVCaptureMetadataOutput?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var cameraPosition: AVCaptureDevice.Position = .back

    // MARK: - Flutter
    private var channel: FlutterMethodChannel?
    private var imageCaptureResult: FlutterResult? = nil

    // MARK: - Zoom
    private var minZoomFactor: CGFloat = 1.0
    private var lastZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat {
        return min(self.captureDevice?.activeFormat.videoMaxZoomFactor ?? 1.0, 8.0)
    }

    // MARK: - OCR rotation (kept for compatibility)
    private var forcedQuarterTurns: Int = 0

    // MARK: - Macro
    private var isMacroEnabled: Bool = false

    // MARK: - Vision
    private let visionQueue = DispatchQueue(label: "vision.barcode.queue", qos: .userInitiated)
    private var frameIndex = 0
    private var visionStrideN = 3 // run Vision every Nth frame

    // MARK: - Dedup / Debounce
    private var lastPayload: String?
    private var lastTypeCode: Int?
    private var lastEmitTs: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    // MARK: - Config
    private var focusRequired: Bool = true
    private var viewId: Int64 = 0
    private var wantedAVTypes: [AVMetadataObject.ObjectType] = [
        .ean13, .qr, .pdf417, .interleaved2of5, .code128, .aztec, .code39, .code39Mod43,
        .code93, .dataMatrix, .ean8, .itf14
    ]
    private var roiWidthPercent: CGFloat = 0.6
    private var roiHeightPercent: CGFloat = 0.4

    // MARK: - Photo output
    private let photoOutput: AVCapturePhotoOutput = {
        let o = AVCapturePhotoOutput()
        o.setPreparedPhotoSettingsArray(
            [AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])],
            completionHandler: nil
        )
        return o
    }()

    // MARK: - Lifecycle
    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        let container = CameraContainerView(frame: frame)
        _view = container
        _view.backgroundColor = .black
        self.viewId = viewId
        super.init()

        if let myArgs = args as? [String: Any],
           let focus = myArgs["focusRequired"] as? Bool {
            self.focusRequired = focus
        }

        container.onLayoutSubviews = { [weak self] in
            self?.ensurePreviewLayer()
        }

        setupAVCapture_bootstrapDevice()
        setupCamera()

        channel = FlutterMethodChannel(
            name: "camera_kit_plus/view_\(viewId)",
            binaryMessenger: messenger
        )
        channel?.setMethodCallHandler(handle)

        _view.isUserInteractionEnabled = true
        attachZoomGesturesIfNeeded()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleDeviceOrientationChange),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func view() -> UIView { _view }

    // MARK: - Flutter Methods
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        // Prefer plugin-level getCameraPermission; view keeps redirect for older callers.
        case "getCameraPermission":
            self.requestCameraPermission(result: result)

        case "changeFlashMode":
            let mode = (args?["flashModeID"] as? Int) ?? 0
            changeFlashMode(modeID: mode, result: result)

        case "switchCamera":
            let cameraID = (args?["cameraID"] as? Int) ?? 0
            self.switchCamera(cameraID: cameraID, result: result)

        case "pauseCamera":
            self.pauseCamera(result: result)

        case "resumeCamera":
            self.resumeCamera(result: result)

        case "takePicture":
            self.captureImage(result: result)

        case "setZoom":
            if let z = args?["zoom"] as? Double {
                self.setZoom(factor: CGFloat(z), animated: true)
                result(true)
            } else {
                result(FlutterError(code: "bad_args", message: "zoom (Double) required", details: nil))
            }

        case "resetZoom":
            self.setZoom(factor: 1.0, animated: true)
            result(true)

        case "setOcrRotation":
            let deg = (args?["degrees"] as? Int) ?? 0
            let turns = ((deg / 90) % 4 + 4) % 4
            self.forcedQuarterTurns = turns
            result(true)

        case "clearOcrRotation":
            self.forcedQuarterTurns = 0
            result(true)

        case "setMacro":
            let enabled = (args?["enabled"] as? Bool) ?? false
            self.setMacro(enabled: enabled)
            result(true)

        case "setRoi":
            let w = CGFloat((args?["w"] as? Double) ?? 0.6)
            let h = CGFloat((args?["h"] as? Double) ?? 0.4)
            roiWidthPercent = max(0.1, min(w, 1.0))
            roiHeightPercent = max(0.1, min(h, 1.0))
            updateRectOfInterest()
            result(true)

        case "dispose":
            self.dispose()
            result(true)

        default:
            result(false)
        }
    }

    // MARK: - Permissions
    func requestCameraPermission(result: @escaping FlutterResult) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            result(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { result(granted) }
            }
        case .denied, .restricted:
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL)
            }
            result(false)
        @unknown default:
            result(false)
        }
    }

    private func permissionGranted() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined, .denied, .restricted: return false
        @unknown default: return false
        }
    }

    // MARK: - Preview / ROI / Orientation
    private func ensurePreviewLayer() {
        if previewLayer == nil {
            let pl = AVCaptureVideoPreviewLayer(session: self.captureSession)
            pl.videoGravity = .resizeAspectFill
            pl.frame = self._view.layer.bounds
            self._view.layer.addSublayer(pl)
            self.previewLayer = pl
        } else {
            previewLayer?.frame = self._view.layer.bounds
        }
        updateVideoOrientation()
        updateRectOfInterest()
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

    private func updateRectOfInterest() {
        guard let pl = previewLayer, let mo = metadataOutputRef else { return }
        let viewRect = self._view.bounds
        guard viewRect.width > 0, viewRect.height > 0 else { return }

        let w = viewRect.width * roiWidthPercent
        let h = viewRect.height * roiHeightPercent
        let roiInView = CGRect(x: (viewRect.width - w) / 2.0,
                               y: (viewRect.height - h) / 2.0,
                               width: w, height: h)
        mo.rectOfInterest = pl.metadataOutputRectConverted(fromLayerRect: roiInView)
    }

    @objc private func handleDeviceOrientationChange() {
        DispatchQueue.main.async {
            self.updateVideoOrientation()
            self.ensurePreviewLayer()
        }
    }

    // MARK: - Setup
    private func setupAVCapture_bootstrapDevice() {
        captureSession.sessionPreset = .hd1920x1080
        if cameraPosition == .back, let dev = bestBackCamera() {
            captureDevice = dev
        } else if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition) {
            captureDevice = dev
        }
    }

    private func bestBackCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first
    }

    private func setupCamera() {
        guard let device = self.captureDevice else { return }

        captureSession.beginConfiguration()

        if captureSession.canSetSessionPreset(.hd4K3840x2160) {
            captureSession.sessionPreset = .hd4K3840x2160
        } else {
            captureSession.sessionPreset = .hd1920x1080
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            } else {
                print("Could not add video input")
                captureSession.commitConfiguration()
                return
            }
        } catch {
            print("Failed to create input: \(error)")
            captureSession.commitConfiguration()
            return
        }

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self,
                 queue: DispatchQueue(label: "metadata.queue", qos: .userInitiated))
            metadataOutput.metadataObjectTypes = wantedAVTypes
            self.metadataOutputRef = metadataOutput
        }

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
            videoDataOutput.setSampleBufferDelegate(self, queue: visionQueue)
        }

        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }

            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= CMTime(value: 1, timescale: 15) }) {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            device.unlockForConfiguration()
        } catch {
            print("Device configuration error: \(error)")
        }

        captureSession.commitConfiguration()
        applyFocusConfiguration()
        ensurePreviewLayer()
        startSession()
    }

    // MARK: - Session control
    private func startSession() {
        DispatchQueue.main.async {
            guard self._view.bounds.width > 0, self._view.bounds.height > 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.startSession() }
                return
            }
            if !self.permissionGranted() {
                self.addButtonToView()
                return
            }
            self.ensurePreviewLayer()
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    func pauseCamera(result: @escaping FlutterResult) {
        captureSession.stopRunning()
        result(true)
    }

    func resumeCamera(result: @escaping FlutterResult) {
        if !captureSession.isRunning { captureSession.startRunning() }
        result(true)
    }

    // MARK: - Photo
    func captureImage(result: @escaping FlutterResult) {
        self.imageCaptureResult = result
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(.auto) {
            settings.flashMode = .auto
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let imageData = photo.fileDataRepresentation() else {
            self.imageCaptureResult?(FlutterError(code: "IMAGE_CAPTURE_FAILED", message: "Could not get image data", details: nil))
            return
        }
        let filename = UUID().uuidString + ".jpg"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL)
            self.imageCaptureResult?(fileURL.path)
        } catch {
            self.imageCaptureResult?(FlutterError(code: "SAVE_FAILED", message: "Could not save image", details: nil))
        }
    }

    // MARK: - Flash / Torch
    func setFlashMode(mode: AVCaptureDevice.TorchMode) {
        guard let d = captureDevice, d.hasTorch, cameraPosition == .back else { return }
        do {
            try d.lockForConfiguration()
            d.torchMode = mode
            d.unlockForConfiguration()
        } catch { print("torch mode error: \(error)") }
    }

    func setTorch(level: Float = 0.35) {
        guard let d = captureDevice, d.hasTorch else { return }
        do {
            try d.lockForConfiguration()
            if level <= 0 {
                d.torchMode = .off
            } else {
                try d.setTorchModeOn(level: min(max(level, 0.01), 1.0))
            }
            d.unlockForConfiguration()
        } catch { print("torch level error: \(error)") }
    }

    func changeFlashMode(modeID: Int, result: @escaping FlutterResult) {
        // 0=off,1=on,2=auto -> torch has no true auto; map 2 to on
        let mode: AVCaptureDevice.TorchMode = (modeID == 2) ? .on : (modeID == 1 ? .on : .off)
        setFlashMode(mode: mode)
        result(true)
    }

    // MARK: - Focus / Macro / Zoom
    private func applyFocusConfiguration() {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            device.isSubjectAreaChangeMonitoringEnabled = true

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }

            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = isMacroEnabled ? .near : .none
            }

            // When focusRequired is false, lock focus near infinity (matches Android AF_OFF).
            if !focusRequired {
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: 0.0, completionHandler: nil)
                }
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }

            device.unlockForConfiguration()

            // MAIN THREAD for channel
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.channel?.invokeMethod("onMacroChanged", arguments: self.buildMacroStatus())
            }
        } catch {
            print("applyFocusConfiguration error: \(error)")
        }
    }

    private func buildMacroStatus() -> [String: Any] {
        var status: [String: Any] = ["requestedMacro": isMacroEnabled]
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
        status["lensPosition"] = d.lensPosition
        return status
    }

    private func setMacro(enabled: Bool) {
        isMacroEnabled = enabled
        switchBackCamera(preferUltraWide: enabled)
        applyFocusConfiguration()
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
            device.unlockForConfiguration()
            lastZoomFactor = clamped

            // MAIN THREAD for channel
            DispatchQueue.main.async { [weak self] in
                self?.channel?.invokeMethod("onZoomChanged", arguments: clamped)
            }
        } catch { print("setZoom error: \(error)") }
    }

    // MARK: - Camera Switching
    private func switchBackCamera(preferUltraWide: Bool) {
        guard cameraPosition == .back else { return }
        let target: AVCaptureDevice? = {
            if preferUltraWide {
                return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            } else {
                return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            }
        }()
        guard let newDevice = target else { return }

        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)

            captureSession.beginConfiguration()
            for input in captureSession.inputs {
                if let dInput = input as? AVCaptureDeviceInput, dInput.device.hasMediaType(.video) {
                    captureSession.removeInput(dInput)
                }
            }
            if captureSession.canAddInput(newInput) {
                captureSession.addInput(newInput)
                self.captureDevice = newDevice
            }
            captureSession.commitConfiguration()

            applyFocusConfiguration()
            ensurePreviewLayer()
        } catch {
            print("switchBackCamera error: \(error)")
        }
    }

    func switchCamera(cameraID: Int, result: @escaping FlutterResult) {
        let targetPos: AVCaptureDevice.Position = (cameraID == 0) ? .back : .front
        guard targetPos != cameraPosition else { result(true); return }
        cameraPosition = targetPos

        captureSession.stopRunning()
        captureSession = AVCaptureSession()

        if cameraPosition == .back {
            captureDevice = bestBackCamera() ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        } else {
            captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        setupCamera()
        result(true)
    }

    // MARK: - Gestures
    private func attachZoomGesturesIfNeeded() {
        if let grs = _view.gestureRecognizers, grs.isEmpty == false { return }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        _view.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapResetZoom))
        doubleTap.numberOfTapsRequired = 2
        _view.addGestureRecognizer(doubleTap)
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
            } catch { print("Zoom lock error: \(error)") }
        case .ended, .cancelled, .failed:
            let target = max(minZoomFactor, min(device.videoZoomFactor, maxZoomFactor))
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: target, withRate: 8.0)
                device.unlockForConfiguration()

                // MAIN THREAD for channel
                DispatchQueue.main.async { [weak self] in
                    self?.channel?.invokeMethod("onZoomChanged", arguments: target)
                }
            } catch { print("Zoom end error: \(error)") }
            lastZoomFactor = target
        default: break
        }
    }

    @objc private func handleDoubleTapResetZoom() {
        setZoom(factor: 1.0, animated: true)
    }

    // MARK: - Permission Button
    private var hasButton = false
    func addButtonToView() {
        if hasButton { return }
        let button = UIButton(type: .system)
        button.setTitle("Need Camera Permission!", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .black
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        _view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: _view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: _view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 250),
            button.heightAnchor.constraint(equalToConstant: 50)
        ])
        hasButton = true
    }

    @objc func buttonTapped() {
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        }
    }

    // MARK: - Metadata Delegate (AV fast path)
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let mo = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = mo.stringValue else { return }

        let typeCode = intBarcodeCode(for: mo.type)
        // AV gives image-space points
        let points: [CKPPoint] = mo.corners.map { CKPPoint($0) }
        emitBarcodeIfNew(value: value, typeCode: typeCode, cornerPoints: points)
    }

    // MARK: - Vision Delegate (robust path)
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameIndex += 1
        if frameIndex % visionStrideN != 0 { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let req = VNDetectBarcodesRequest { [weak self] request, _ in
            guard let self = self else { return }
            guard let results = request.results as? [VNBarcodeObservation], !results.isEmpty else { return }

            // pick highest confidence
            guard let best = results.sorted(by: { $0.confidence > $1.confidence }).first,
                  let value = best.payloadStringValue else { return }

            let typeCode = self.intBarcodeCode(for: best.symbology)

            // Vision has normalized boundingBox (no cornerPoints API).
            let bb = best.boundingBox
            let points = [
                CKPPoint(x: Double(bb.minX), y: Double(bb.minY)),
                CKPPoint(x: Double(bb.maxX), y: Double(bb.minY)),
                CKPPoint(x: Double(bb.maxX), y: Double(bb.maxY)),
                CKPPoint(x: Double(bb.minX), y: Double(bb.maxY))
            ]
            self.emitBarcodeIfNew(value: value, typeCode: typeCode, cornerPoints: points)
        }
        req.symbologies = visionSymbologies(for: wantedAVTypes)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([req]) } catch { /* ignore */ }
    }

    // MARK: - Emit helper (debounce + to Flutter)
    private func emitBarcodeIfNew(value: String,
                                  typeCode: Int,
                                  cornerPoints: [CKPPoint]) {
        let now = CFAbsoluteTimeGetCurrent()
        if value == lastPayload, typeCode == lastTypeCode, now - lastEmitTs < 0.5 { return }
        lastPayload = value
        lastTypeCode = typeCode
        lastEmitTs = now

        DispatchQueue.main.async {
            self.channel?.invokeMethod("onBarcodeScanned", arguments: value)
            let payload = CKPBarcodeData(value: value, type: typeCode, cornerPoints: cornerPoints)
            if let jsonData = try? JSONEncoder().encode(payload),
               let json = String(data: jsonData, encoding: .utf8) {
                self.channel?.invokeMethod("onBarcodeDataScanned", arguments: json)
            }
        }
    }

    // MARK: - Dispose
    func dispose() {
        captureSession.stopRunning()
        channel?.setMethodCallHandler(nil)
        channel = nil
    }

    // MARK: - Type mapping
    func intBarcodeCode(for type: AVMetadataObject.ObjectType) -> Int {
        switch type {
        case .aztec:                return 4096
        case .code39:               return 2
        case .code39Mod43:          return 2
        case .code93:               return 4
        case .code128:              return 1
        case .dataMatrix:           return 16
        case .ean8:                 return 64
        case .ean13:                return 32
        case .interleaved2of5:      return 128
        case .itf14:                return 128
        case .pdf417:               return 2048
        case .qr:                   return 256
        default:                    return 0
        }
    }

    func intBarcodeCode(for sym: VNBarcodeSymbology) -> Int {
        switch sym {
        case .aztec:        return 4096
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: return 2
        case .code93:       return 4
        case .code128:      return 1
        case .dataMatrix:   return 16
        case .ean8:         return 64
        case .ean13:        return 32
        case .I2of5:        return 128   // Vision name for Interleaved 2 of 5
        case .ITF14:        return 128
        case .pdf417:       return 2048
        case .qr:           return 256
        case .upce:         return 0     // map if needed
        default:            return 0
        }
    }

    private func visionSymbologies(for avTypes: [AVMetadataObject.ObjectType]) -> [VNBarcodeSymbology] {
        var set = Set<VNBarcodeSymbology>()
        for av in avTypes {
            switch av {
            case .aztec:                set.insert(.aztec)
            case .code39, .code39Mod43: set.insert(.code39)
            case .code93:               set.insert(.code93)
            case .code128:              set.insert(.code128)
            case .dataMatrix:           set.insert(.dataMatrix)
            case .ean8:                 set.insert(.ean8)
            case .ean13:                set.insert(.ean13)
            case .interleaved2of5:      set.insert(.I2of5)   // correct Vision case
            case .itf14:                set.insert(.ITF14)
            case .pdf417:               set.insert(.pdf417)
            case .qr:                   set.insert(.qr)
            default: break
            }
        }
        return Array(set)
    }
}
