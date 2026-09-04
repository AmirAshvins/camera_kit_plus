import 'camera_kit_plus_platform_interface.dart';

export 'camera_kit_plus_view.dart';
export 'camera_kit_ocr_plus_view.dart';
export 'camera_kit_plus_controller.dart';
export 'enums.dart';

/// Plugin-level APIs (platform version, permission). View commands go through
/// [CameraKitPlusController] bound to a platform view.
class CameraKitPlus {
  Future<String?> getPlatformVersion() {
    return CameraKitPlusPlatform.instance.getPlatformVersion();
  }

  Future<bool> getCameraPermission() {
    return CameraKitPlusPlatform.instance.getCameraPermission();
  }
}
