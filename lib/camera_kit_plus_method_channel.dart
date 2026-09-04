import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'camera_kit_plus_platform_interface.dart';

/// Plugin-level MethodChannel (`camera_kit_plus`) for version/permission only.
class MethodChannelCameraKitPlus extends CameraKitPlusPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('camera_kit_plus');

  @override
  Future<String?> getPlatformVersion() async {
    return methodChannel.invokeMethod<String>('getPlatformVersion');
  }

  @override
  Future<bool> getCameraPermission() async {
    return await methodChannel.invokeMethod<bool>('getCameraPermission') ??
        false;
  }
}
