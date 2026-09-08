import 'dart:async';
import 'dart:convert';

import 'package:camera_kit_plus/enums.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'camera_kit_plus_controller.dart';

/// Barcode / QR scanner platform view.
class CameraKitPlusView extends StatefulWidget {
  /// Called with the raw barcode string when a code is scanned.
  final void Function(String code)? onBarcodeRead;

  /// Called with structured barcode data when available.
  final void Function(BarcodeData data)? onBarcodeDataRead;

  /// Shows the scanner frame overlay asset.
  final bool showFrame;

  /// Shows an on-screen zoom slider.
  final bool showZoomSlider;

  /// Optional symbology filter for [onBarcodeDataRead].
  final List<BarcodeType>? types;

  /// Optional external controller; created internally when null.
  final CameraKitPlusController? controller;

  /// When true, tap-to-focus and subject-area re-AF are enabled. Continuous AF always runs.
  final bool focusRequired;

  /// `high` uses 1080p / ~20 fps for PDF417; anything else stays 720p / 15 fps.
  final String? scanQuality;

  /// When true, native runs gated printed-text OCR for overlay chips.
  final bool textAssist;

  /// Called with raw OCR text from [textAssist] (not a barcode).
  final void Function(String text)? onTextAssist;

  /// Creates a barcode scanner view.
  const CameraKitPlusView({
    super.key,
    required this.onBarcodeRead,
    this.onBarcodeDataRead,
    this.controller,
    this.types,
    this.showFrame = false,
    this.showZoomSlider = false,
    this.focusRequired = true,
    this.scanQuality,
    this.textAssist = false,
    this.onTextAssist,
  });

  @override
  State<CameraKitPlusView> createState() => _CameraKitPlusViewState();
}

class _CameraKitPlusViewState extends State<CameraKitPlusView>
    with WidgetsBindingObserver {
  late CameraKitPlusController controller;
  bool isVisible = false;
  double zoom = 1;

  /// Per-instance key — shared const keys break [VisibilityDetector] tracking
  /// when multiple scanners are mounted (mode switches, dialogs, covered routes).
  late final Key _visibilityKey =
      Key('camera-kit-plus-view-${identityHashCode(this)}');

  @override
  void initState() {
    controller = widget.controller ?? CameraKitPlusController();
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isVisible) {
      controller.resumeCamera();
    } else {
      controller.pauseCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // VisibilityDetector often skips fraction=0 on dispose; always stop capture
    // before clearing the channel — including external (host-owned) controllers.
    unawaited(_releaseCamera());
    super.dispose();
  }

  /// Stops native capture then unbinds the per-view method channel.
  ///
  /// Host controllers are rebound via [CameraKitPlusController.bindToView] when
  /// a new platform view is created after remount.
  Future<void> _releaseCamera() async {
    if (controller.isBound) {
      await controller.disposeView();
    } else {
      controller.unbind();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        VisibilityDetector(
          key: _visibilityKey,
          onVisibilityChanged: _onVisibilityChanged,
          child: _buildPlatformView(),
        ),
        if (widget.showFrame) _buildFrame(),
        if (widget.showZoomSlider) _buildZoomSlider(),
      ],
    );
  }

  Widget _buildPlatformView() {
    const String viewType = 'camera-kit-plus-view';
    final Map<String, dynamic> creationParams = <String, dynamic>{
      'focusRequired': widget.focusRequired,
      if (widget.scanQuality != null) 'scanQuality': widget.scanQuality,
      'textAssist': widget.textAssist,
    };

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: viewType,
          onPlatformViewCreated: _onPlatformViewCreated,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: viewType,
          onPlatformViewCreated: _onPlatformViewCreated,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
      default:
        return Text(
          '$defaultTargetPlatform is not yet supported by the camera_kit_plus plugin',
        );
    }
  }

  Widget _buildFrame() {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: MediaQuery.of(context).size.width * 0.9,
          height: MediaQuery.of(context).size.width * 0.9 * 0.7,
          child: Image.asset(
            'assets/images/scanner_frame.png',
            package: 'camera_kit_plus',
            fit: BoxFit.fill,
          ),
        ),
      ),
    );
  }

  Widget _buildZoomSlider() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: 40,
        margin: const EdgeInsets.only(bottom: 24),
        child: Slider(
          min: 1,
          max: 8,
          value: zoom,
          onChanged: (value) {
            setState(() => zoom = value);
            controller.setZoom(value);
          },
        ),
      ),
    );
  }

  void _onPlatformViewCreated(int id) {
    controller.bindToView(id, onEvent: _methodCallHandler);
  }

  Future<dynamic> _methodCallHandler(MethodCall methodCall) async {
    switch (methodCall.method) {
      case 'onBarcodeScanned':
        widget.onBarcodeRead?.call(methodCall.arguments.toString());
        break;
      case 'onTextAssist':
        widget.onTextAssist?.call(methodCall.arguments.toString());
        break;
      case 'onBarcodeDataScanned':
        final data =
            BarcodeData.fromJson(jsonDecode(methodCall.arguments.toString()));
        if (widget.types == null ||
            widget.types!.map((t) => t.code).contains(data.type)) {
          widget.onBarcodeRead?.call(data.value);
          widget.onBarcodeDataRead?.call(data);
        }
        break;
      case 'onZoomChanged':
        final zoomArg = methodCall.arguments;
        if (zoomArg is num) {
          setState(() => zoom = zoomArg.toDouble());
        }
        break;
      case 'onMacroChanged':
        // Native may send a status map that includes zoom when macro toggles.
        final args = methodCall.arguments;
        if (args is Map) {
          final z = args['zoomRatio'] ?? args['zoomFactor'];
          if (z is num) {
            setState(() => zoom = z.toDouble());
          }
        }
        break;
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final bool newVisibility = info.visibleFraction > 0;
    if (newVisibility != isVisible) {
      isVisible = newVisibility;
      if (isVisible) {
        controller.resumeCamera();
      } else {
        controller.pauseCamera();
      }
    }
  }
}

/// Structured barcode payload from native.
class BarcodeData {
  /// Corner points of the barcode in image space.
  final List<CornerPoint> cornerPoints;

  /// Symbology type code.
  final int type;

  /// Decoded string value.
  final String value;

  /// Creates barcode data.
  BarcodeData({
    required this.cornerPoints,
    required this.type,
    required this.value,
  });

  /// Parses JSON produced by native barcode scanning.
  factory BarcodeData.fromJson(Map<String, dynamic> json) => BarcodeData(
        cornerPoints: List<CornerPoint>.from(
          json['cornerPoints'].map((x) => CornerPoint.fromJson(x)),
        ),
        type: json['type'],
        value: json['value'],
      );

  /// Maps [type] to [BarcodeType].
  BarcodeType get getType => BarcodeType.fromCode(type);
}

/// A 2D point in image coordinates.
class CornerPoint {
  /// X coordinate.
  final double x;

  /// Y coordinate.
  final double y;

  /// Creates a corner point.
  CornerPoint({required this.x, required this.y});

  /// Parses JSON `{x, y}`.
  factory CornerPoint.fromJson(Map<String, dynamic> json) =>
      CornerPoint(x: (json['x'] as num).toDouble(), y: (json['y'] as num).toDouble());
}
