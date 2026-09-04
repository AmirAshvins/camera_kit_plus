import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'camera_kit_plus_controller.dart';

/// Live OCR platform view backed by native ML Kit (Android) / Vision (iOS).
class CameraKitOcrPlusView extends StatefulWidget {
  /// Called for each OCR frame result.
  final void Function(OcrData data)? onTextRead;

  /// Called when native zoom changes (pinch / macro).
  final void Function(double zoom)? onZoomChanged;

  /// Shows the scanner frame overlay asset.
  final bool showFrame;

  /// Shows an on-screen zoom slider.
  final bool showZoomSlider;

  /// Asks native to draw text bounding rectangles.
  final bool showTextRectangles;

  /// Optional external controller; created internally when null.
  final CameraKitPlusController? controller;

  /// When true, native continuous AF taps are more aggressive.
  final bool focusRequired;

  /// Creates an OCR camera view.
  const CameraKitOcrPlusView({
    super.key,
    required this.onTextRead,
    this.controller,
    this.onZoomChanged,
    this.showFrame = false,
    this.showZoomSlider = false,
    this.showTextRectangles = false,
    this.focusRequired = false,
  });

  @override
  State<CameraKitOcrPlusView> createState() => _CameraKitOcrPlusViewState();
}

class _CameraKitOcrPlusViewState extends State<CameraKitOcrPlusView>
    with WidgetsBindingObserver {
  late CameraKitPlusController controller;
  bool _ownsController = false;
  bool isVisible = false;
  double zoom = 1;

  @override
  void initState() {
    _ownsController = widget.controller == null;
    controller = widget.controller ?? CameraKitPlusController();
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        VisibilityDetector(
          key: const Key('camera-kit-ocr-plus-view'),
          onVisibilityChanged: _onVisibilityChanged,
          child: _buildPlatformView(),
        ),
        if (widget.showFrame) _buildFrame(),
        if (widget.showZoomSlider) _buildZoomSlider(),
      ],
    );
  }

  Widget _buildPlatformView() {
    const String viewType = 'camera-kit-ocr-plus-view';
    final Map<String, dynamic> creationParams = <String, dynamic>{
      'showTextRectangles': widget.showTextRectangles,
      'focusRequired': widget.focusRequired,
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
    if (_ownsController) {
      controller.disposeView();
    } else {
      controller.unbind();
    }
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    controller.bindToView(id, onEvent: _methodCallHandler);
  }

  Future<dynamic> _methodCallHandler(MethodCall methodCall) async {
    switch (methodCall.method) {
      case 'onTextRead':
        final data =
            OcrData.fromJson(jsonDecode(methodCall.arguments.toString()));
        widget.onTextRead?.call(data);
        break;
      case 'onZoomChanged':
        final zoomArg = methodCall.arguments;
        if (zoomArg is num) {
          final z = zoomArg.toDouble();
          setState(() => zoom = z);
          widget.onZoomChanged?.call(z);
        }
        break;
      case 'onMacroChanged':
        // Native may send a status map that includes zoom when macro toggles.
        final args = methodCall.arguments;
        if (args is Map) {
          final z = args['zoomRatio'] ?? args['zoomFactor'];
          if (z is num) {
            setState(() => zoom = z.toDouble());
            widget.onZoomChanged?.call(z.toDouble());
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

/// OCR result payload matching native `OcrData` JSON.
class OcrData {
  /// Creates OCR data.
  OcrData({
    required this.text,
    this.path = '',
    this.orientation = 0,
    required this.lines,
  });

  /// Full recognized text (lines joined by newlines).
  String text;

  /// Optional still-image path.
  String path;

  /// UIImage orientation raw value when known.
  int orientation;

  /// Per-line text and corner points.
  List<OcrLine> lines;

  /// Parses JSON from native `onTextRead`.
  factory OcrData.fromJson(Map<String, dynamic> json) => OcrData(
        text: json['text'],
        path: json['path'] ?? '',
        orientation: json['orientation'] ?? 0,
        lines: List<OcrLine>.from(
          (json['lines'] ?? []).map((x) => OcrLine.fromJson(x)),
        ),
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'text': text,
        'path': path,
        'orientation': orientation,
        'lines': List<dynamic>.from(lines.map((x) => x.toJson())),
      };
}

/// A single OCR text line.
class OcrLine {
  /// Creates an OCR line.
  OcrLine({
    required this.text,
    required this.cornerPoints,
  });

  /// Recognized line text.
  String text;

  /// Bounding quad in image-pixel space.
  List<OcrPoint> cornerPoints;

  /// Parses JSON (supports legacy `a`/`b` keys).
  factory OcrLine.fromJson(Map<String, dynamic> json) => OcrLine(
        text: json['text'] ?? json['a'] ?? '',
        cornerPoints: List<OcrPoint>.from(
          (json['cornerPoints'] ?? json['b'] ?? [])
              .map((x) => OcrPoint.fromJson(x)),
        ),
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'text': text,
        'cornerPoints': List<dynamic>.from(cornerPoints.map((x) => x.toJson())),
      };
}

/// A point in image-pixel coordinates.
class OcrPoint {
  /// Creates an OCR point.
  OcrPoint({
    required this.x,
    required this.y,
  });

  /// X coordinate.
  double x;

  /// Y coordinate.
  double y;

  /// Parses JSON (supports legacy `a`/`b` keys).
  factory OcrPoint.fromJson(Map<String, dynamic> json) => OcrPoint(
        x: (json['x'] ?? json['a']).toDouble(),
        y: (json['y'] ?? json['b']).toDouble(),
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
      };
}
