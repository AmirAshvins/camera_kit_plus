# camera_kit_plus

Flutter plugin for live **barcode/QR** scanning and **OCR** (MRZ-friendly text).

| Platform | Preview | Barcode | OCR |
|----------|---------|---------|-----|
| Android | CameraX | ML Kit barcode | ML Kit text recognition |
| iOS | AVFoundation | AVMetadata + Vision fallback | Apple Vision (`VNRecognizeTextRequest`) |

## Usage

```dart
import 'package:camera_kit_plus/camera_kit_plus.dart';

final controller = CameraKitPlusController();

// Barcode
CameraKitPlusView(
  controller: controller,
  onBarcodeRead: (code) {},
  onBarcodeDataRead: (data) {},
);

// OCR
CameraKitOcrPlusView(
  controller: controller,
  onTextRead: (ocr) {},
);

// After the platform view is created, the same controller is bound to
// MethodChannel('camera_kit_plus/view_$id') for pause/flash/zoom/macro/etc.
await controller.changeFlashMode(CameraKitPlusFlashMode.on);
await controller.pauseCamera();
```

Plugin-level APIs (not view-bound):

```dart
final kit = CameraKitPlus();
await kit.getPlatformVersion();
await kit.getCameraPermission();
```

## iOS notes

- Minimum iOS **13.0**. OCR uses the system Vision framework (no Google ML Kit).
- Prefer Swift Package Manager via Flutter’s generated plugin package; CocoaPods fallback still ships `ios/camera_kit_plus.podspec`.
- Add `NSCameraUsageDescription` to the host `Info.plist`.

## Android notes

- minSdk 21. Uses CameraX + ML Kit.
- Declare `CAMERA` permission in the host app.

## Channels

- `camera_kit_plus` — `getPlatformVersion`, `getCameraPermission`
- `camera_kit_plus/view_$viewId` — view commands + events (`onBarcodeScanned`, `onTextRead`, …)
