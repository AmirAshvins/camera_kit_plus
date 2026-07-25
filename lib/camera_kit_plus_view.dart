import 'dart:convert';
import 'dart:io';

import 'package:camera_kit_plus/enums.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'camera_kit_plus_controller.dart';

class CameraKitPlusView extends StatefulWidget {
  final void Function(String code)? onBarcodeRead;
  final void Function(BarcodeData data)? onBarcodeDataRead;
  final bool showFrame;
  final bool showZoomSlider;
  final List<BarcodeType>? types;
  final CameraKitPlusController? controller;
  final bool focusRequired;

  const CameraKitPlusView({
    super.key,
    required this.onBarcodeRead,
    this.onBarcodeDataRead,
    this.controller,
    this.types,
    this.showFrame = false,
    this.showZoomSlider = false,
    this.focusRequired = true,
  });

  @override
  State<CameraKitPlusView> createState() => _CameraKitPlusViewState();
}

class _CameraKitPlusViewState extends State<CameraKitPlusView> with WidgetsBindingObserver {
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        VisibilityDetector(
          key: const Key('camera-kit-plus-view'),
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

  void _onPlatformViewCreated(int id) {
    channel.setMethodCallHandler(_methodCallHandler);
  }

  Future<dynamic> _methodCallHandler(MethodCall methodCall) async {
    switch (methodCall.method) {
      case "onBarcodeScanned":
        widget.onBarcodeRead?.call(methodCall.arguments.toString());
        break;
      case "onBarcodeDataScanned":
        final data = BarcodeData.fromJson(jsonDecode(methodCall.arguments.toString()));
        if (widget.types == null || widget.types!.map((t) => t.code).contains(data.type)) {
          widget.onBarcodeRead?.call(data.value);
          widget.onBarcodeDataRead?.call(data);
        }
        break;
      case "onZoomChanged":
        if (methodCall.arguments is double) {
          setState(() => zoom = methodCall.arguments);
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

class BarcodeData {
  final List<CornerPoint> cornerPoints;
  final int type;
  final String value;

  BarcodeData({required this.cornerPoints, required this.type, required this.value});

  factory BarcodeData.fromJson(Map<String, dynamic> json) => BarcodeData(
        cornerPoints: List<CornerPoint>.from(json["cornerPoints"].map((x) => CornerPoint.fromJson(x))),
        type: json["type"],
        value: json["value"],
      );

  BarcodeType get getType => BarcodeType.fromCode(type);
}

class CornerPoint {
  final double x;
  final double y;

  CornerPoint({required this.x, required this.y});

  factory CornerPoint.fromJson(Map<String, dynamic> json) => CornerPoint(x: json["x"], y: json["y"]);
}
