import 'package:flutter/services.dart';

import 'camera_kit_plus.dart';

/// Whether a visibility/lifecycle callback may resume capture.
///
/// Host [CameraKitPlusController.pauseCamera] latches [hostPaused] so a
/// covered platform view that still reports [visibleFraction] > 0 cannot
/// restart the session under another route.
bool cameraKitPlusAllowsAutoResume({
  required bool hostPaused,
  required double visibleFraction,
}) {
  return !hostPaused && visibleFraction >= 0.5;
}

/// Binds [controller] to [viewId], then stops native capture if the Dart
/// widget already disposed.
///
/// [UiKitView] / [AndroidView] can fire `onPlatformViewCreated` after
/// [State.dispose]. Binding is still required so [CameraKitPlusController.disposeView]
/// has a method channel; without it a late native session stays running with
/// no widget (iPhone camera indicator stays on).
///
/// [onEvent] is forwarded to [CameraKitPlusController.bindToView].
/// [released] is true when the Dart [State] has already been disposed.
Future<void> cameraKitPlusBindPlatformView({
  required CameraKitPlusController controller,
  required int viewId,
  Future<dynamic> Function(MethodCall call)? onEvent,
  required bool released,
}) async {
  controller.bindToView(viewId, onEvent: onEvent);
  if (released) {
    await controller.disposeView();
  }
}

/// Controls a single camera platform view after [bindToView].
///
/// View commands (pause/flash/zoom/…) go to `camera_kit_plus/view_$id`.
/// Plugin-level APIs stay on [CameraKitPlus] (`getPlatformVersion`, permission).
class CameraKitPlusController extends CameraKitPlus {
  MethodChannel? _viewChannel;
  int? _boundViewId;
  Future<dynamic> Function(MethodCall call)? _eventHandler;
  bool _hostPaused = false;

  /// Host hook when a platform view binds (scan session started).
  static void Function(CameraKitPlusController controller)? onViewBound;

  /// Host hook when a platform view unbinds (scan session ended).
  static void Function(CameraKitPlusController controller)? onViewUnbound;

  /// Whether this controller is bound to a native platform view.
  bool get isBound => _viewChannel != null;

  /// Whether the host paused capture and visibility/lifecycle must not resume.
  bool get hostPaused => _hostPaused;

  /// View id currently bound, if any.
  int? get boundViewId => _boundViewId;

  /// Binds this controller to the platform view [viewId] and optionally
  /// installs an event handler for native→Dart callbacks.
  void bindToView(
    int viewId, {
    Future<dynamic> Function(MethodCall call)? onEvent,
  }) {
    _viewChannel?.setMethodCallHandler(null);
    _boundViewId = viewId;
    _eventHandler = onEvent;
    _viewChannel = MethodChannel('camera_kit_plus/view_$viewId');
    _viewChannel!.setMethodCallHandler(_eventHandler);
    _hostPaused = false;
    onViewBound?.call(this);
  }

  /// Clears the view channel handler. Does not stop native capture;
  /// prefer [disposeView] (or [pauseCamera] then [unbind]) when the platform
  /// view is leaving so the session does not stay armed with no Dart channel.
  void unbind() {
    final wasBound = _viewChannel != null;
    _viewChannel?.setMethodCallHandler(null);
    _viewChannel = null;
    _boundViewId = null;
    _eventHandler = null;
    if (wasBound) {
      onViewUnbound?.call(this);
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    final channel = _viewChannel;
    if (channel == null) return null;
    return channel.invokeMethod<T>(method, args);
  }

  /// Pauses native capture.
  ///
  /// When [host] is true (default), visibility and app-lifecycle callbacks
  /// must not call [resumeCamera] until the host resumes. The plugin view
  /// passes `host: false` so a hide/show cycle does not latch.
  Future<bool> pauseCamera({bool host = true}) async {
    if (host) _hostPaused = true;
    return await _invoke<bool>('pauseCamera') ?? false;
  }

  /// Resumes native capture unless a host pause is still latched.
  ///
  /// Visibility/lifecycle must pass `host: false`, which no-ops while
  /// [hostPaused] is true.
  Future<bool> resumeCamera({bool host = true}) async {
    if (!host && _hostPaused) return false;
    if (host) _hostPaused = false;
    return await _invoke<bool>('resumeCamera') ?? false;
  }

  Future<bool> changeFlashMode(CameraKitPlusFlashMode mode) async {
    return await _invoke<bool>('changeFlashMode', {'flashModeID': mode.index}) ??
        false;
  }

  /// Whether the device torch is currently on (native camera state).
  Future<bool> getFlashMode() async {
    try {
      return await _invoke<bool>('getFlashMode') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> switchCamera(CameraKitPlusCameraMode mode) async {
    return await _invoke<bool>('switchCamera', {'cameraID': mode.index}) ??
        false;
  }

  Future<String?> takePicture() async {
    return _invoke<String>('takePicture', {'path': ''});
  }

  Future<bool?> setZoom(double zoom) async {
    return _invoke<bool>('setZoom', {'zoom': zoom});
  }

  Future<bool?> setOcrRotation(int degree) async {
    return _invoke<bool>('setOcrRotation', {'degrees': degree});
  }

  Future<bool?> clearOcrRotation() async {
    return _invoke<bool>('clearOcrRotation');
  }

  Future<bool?> setMacro(bool macro) async {
    try {
      return await _invoke<bool>('setMacro', {'enabled': macro});
    } catch (_) {
      return false;
    }
  }

  Future<bool?> setShowTextRectangles(bool show) async {
    try {
      return await _invoke<bool>('setShowTextRectangles', {'show': show});
    } catch (_) {
      return false;
    }
  }

  /// Asks the native view to release capture resources, then [unbind]s.
  ///
  /// Safe to call when unbound (no-ops the invoke, still clears handlers).
  Future<void> disposeView() async {
    _hostPaused = false;
    await _invoke<bool>('dispose');
    unbind();
  }
}
