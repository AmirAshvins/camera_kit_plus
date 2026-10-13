import 'dart:async';

import 'package:flutter/services.dart';

/// Diagnostic switch for Camera Kit native logs.
class CameraKitPlusLogging {
  CameraKitPlusLogging._();

  static const MethodChannel _channel = MethodChannel('camera_kit_plus');

  /// When true, iOS `print` and Android `Log` calls in the plugin are dropped.
  static bool silentLogs = true;

  /// Updates plugin logging. A missing native plugin (unit tests) is ignored.
  ///
  /// [silentLogs] follows the host scanner/OCR flag.
  static void configure({bool? silentLogs}) {
    if (silentLogs == null) {
      return;
    }
    CameraKitPlusLogging.silentLogs = silentLogs;
    unawaited(_push(silentLogs));
  }

  static Future<void> _push(bool silent) async {
    try {
      await _channel.invokeMethod<void>('setSilentLogs', silent);
    } catch (_) {
      // Desktop tests and hosts without the plugin.
    }
  }
}
