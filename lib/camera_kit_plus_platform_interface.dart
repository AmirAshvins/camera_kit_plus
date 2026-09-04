import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'camera_kit_plus_method_channel.dart';

/// Plugin-level platform APIs (not bound to a camera view).
abstract class CameraKitPlusPlatform extends PlatformInterface {
  /// Constructs a [CameraKitPlusPlatform].
  CameraKitPlusPlatform() : super(token: _token);

  static final Object _token = Object();

  static CameraKitPlusPlatform _instance = MethodChannelCameraKitPlus();

  /// The default instance of [CameraKitPlusPlatform] to use.
  static CameraKitPlusPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class when they register themselves.
  static set instance(CameraKitPlusPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns a descriptive platform version string.
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  /// Requests camera permission and returns whether it is granted.
  Future<bool> getCameraPermission() {
    throw UnimplementedError('getCameraPermission() has not been implemented.');
  }
}
