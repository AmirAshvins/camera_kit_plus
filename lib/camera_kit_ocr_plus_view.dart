import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'camera_kit_plus_controller.dart';

class CameraKitOcrPlusView extends StatefulWidget {
  final void Function(OcrData data)? onTextRead;
  final void Function(double zoom)? onZoomChanged;
  final bool showFrame;
  final bool showZoomSlider;
  final bool showTextRectangles;
  final CameraKitPlusController? controller;
  final bool focusRequired;

  const CameraKitOcrPlusView({
    super.key,
    required this.onTextRead,
    this.controller,
    this.onZoomChanged,
    this.showFrame = false,
    this.showZoomSlider = false,
    this.showTextRectangles = false,
    this.focusRequired = false, // Default to false for OCR
  });

  @override
  State<CameraKitOcrPlusView> createState() => _CameraKitOcrPlusViewState();
}

class _CameraKitOcrPlusViewState extends State<CameraKitOcrPlusView> with WidgetsBindingObserver {
  static const channel = MethodChannel('camera_kit_plus');
  late CameraKitPlusController controller;
  bool isVisible = false;
  double zoom = 1;

  @override
  void initState() {
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
      "showTextRectangles": widget.showTextRectangles,
      "focusRequired": widget.focusRequired,
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
        return Text('$defaultTargetPlatform is not yet supported by the camera_kit_plus plugin');
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
            "assets/images/scanner_frame.png",
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
    // controller.dispose();
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    channel.setMethodCallHandler(_methodCallHandler);
  }

  Future<dynamic> _methodCallHandler(MethodCall methodCall) async {
    switch (methodCall.method) {
      case "onTextRead":
        final data = OcrData.fromJson(jsonDecode(methodCall.arguments.toString()));
        widget.onTextRead?.call(data);
        break;
      case "onZoomChanged":
        if (methodCall.arguments is double) {
          setState(() => zoom = methodCall.arguments);
          widget.onZoomChanged?.call(methodCall.arguments);
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

class OcrData {
  OcrData({
    required this.text,
    this.path = "",
    this.orientation = 0,
    required this.lines,
  });

  String text;
  String path;
  int orientation;
  List<OcrLine> lines;

  factory OcrData.fromJson(Map<String, dynamic> json) => OcrData(
    text: json["text"],
    path: json["path"] ?? "",
    orientation: json["orientation"] ?? 0,
    lines: List<OcrLine>.from((json["lines"] ?? []).map((x) => OcrLine.fromJson(x))),
  );

  Map<String, dynamic> toJson() => {
    "text": text,
    "path": path,
    "orientation": orientation,
    "lines": List<dynamic>.from(lines.map((x) => x.toJson())),
  };
}

class OcrLine {
  OcrLine({
    required this.text,
    required this.cornerPoints,
  });

  String text;
  List<OcrPoint> cornerPoints;

  factory OcrLine.fromJson(Map<String, dynamic> json) => OcrLine(
    text: json["text"] ?? json["a"] ?? "",
    cornerPoints: List<OcrPoint>.from((json["cornerPoints"] ?? json["b"] ?? []).map((x) => OcrPoint.fromJson(x))),
  );

  Map<String, dynamic> toJson() => {
    "text": text,
    "cornerPoints": List<dynamic>.from(cornerPoints.map((x) => x.toJson())),
  };
}

class OcrPoint {
  OcrPoint({
    required this.x,
    required this.y,
  });

  double x;
  double y;

  factory OcrPoint.fromJson(Map<String, dynamic> json) => OcrPoint(
    x: (json["x"] ?? json["a"]).toDouble(),
    y: (json["y"] ?? json["b"]).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    "x": x,
    "y": y,
  };
}

