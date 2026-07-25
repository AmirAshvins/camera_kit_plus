import 'dart:developer';

import 'package:camera_kit_plus/camera_kit_plus_controller.dart';
import 'package:camera_kit_plus/enums.dart';
import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:camera_kit_plus/camera_kit_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';
  final _cameraKitPlusPlugin = CameraKitPlus();
  CameraKitPlusController controller = CameraKitPlusController();
  bool show = true;

  @override
  void initState() {
    super.initState();
    // initPlatformState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    String platformVersion;
    // Platform messages may fail, so we use a try/catch PlatformException.
    // We also handle the message potentially returning null.
    try {
      platformVersion = await _cameraKitPlusPlugin.getPlatformVersion() ?? 'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      initialRoute: "/",
      routes: <String, WidgetBuilder>{
        '/': (BuildContext context) => Home(),
        '/settings': (BuildContext context) => Scaffold(
              appBar: AppBar(),
            ),
      },
    );
  }
}

class Home extends StatelessWidget {
  final _cameraKitPlusPlugin = CameraKitPlus();
  CameraKitPlusController controller = CameraKitPlusController();
  bool show = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blueAccent,
      appBar: AppBar(
        title: const Text('Plugin example app'),
      ),
      body: Center(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            false
                ? Expanded(
                    child: show
                        ? CameraKitPlusView(
                            controller: controller,
                            showZoomSlider: true,
                            onBarcodeRead: (String data) {
                              // print(data);
                              // log("Barcode Scanned =>$data");
                            },
                            onBarcodeDataRead: (BarcodeData data) {
                              log("Barcode Scanned =>${data.getType} -- ${data.value}");
                            },
                          )
                        : SizedBox())
                : Expanded(
                    child: Stack(
                    children: [
                      CameraKitOcrPlusView(
                        showFrame: true,
                        showZoomSlider: true,
                        focusRequired: true,
                        onZoomChanged: (double zoom) {
                          log("zoom is ${zoom}");
                        },
                        controller: controller,
                        onTextRead: (OcrData data) {
                          log(data.text);
                        },
                      ),
                    ],
                  )),
            TextButton(
                onPressed: () {
                  controller.takePicture().then((s) {
                    log("$s");
                  });
                  // Navigator.pushNamed(context, "/settings");
                },
                child: Text("Push"))

            // Expanded(
            //   child: Container(
            //     color: Colors.red,
            //     child: Column(
            //       children: [
            //         TextButton(
            //           onPressed: () {
            //             controller.setZoom(3.0);
            //
            //             // controller.setMacro(true);
            //           },
            //           child: Text("macro on"),
            //         ),
            //         TextButton(
            //           onPressed: () {
            //             controller.setZoom(1.0);
            //             // controller.setMacro(false);
            //           },
            //           child: Text("macro off"),
            //         ),
            //         TextButton(
            //           onPressed: () {
            //             controller.changeFlashMode(CameraKitPlusFlashMode.off);
            //           },
            //           child: Text("off"),
            //         ),
            //         TextButton(
            //           onPressed: () {
            //             controller.changeFlashMode(CameraKitPlusFlashMode.on);
            //           },
            //           child: Text("on"),
            //         ),
            //         TextButton(
            //           onPressed: () async {
            //             // controller.switchCamera(CameraKitPlusCameraMode.back);
            //             final roateta = await controller.setOcrRotation(270);
            //             log("roateta ${roateta}");
            //           },
            //           child: Text("rotate"),
            //         ),
            //         // TextButton(
            //         //   onPressed: () {
            //         //     controller.switchCamera(CameraKitPlusCameraMode.front);
            //         //   },
            //         //   child: Text("front"),
            //         // ),
            //         TextButton(
            //           onPressed: () async {
            //             try {
            //               final path = await controller.takePicture();
            //               log("path:${path}");
            //             } catch (e) {
            //               log("$e");
            //             }
            //           },
            //           child: Text("take picture"),
            //         ),
            //         TextButton(
            //           onPressed: () async {
            //             show = false;
            //             setState(() {});
            //             await Future.delayed(Duration(seconds: 1));
            //             show = true;
            //             setState(() {});
            //           },
            //           child: Text("reload"),
            //         ),
            //       ],
            //     ),
            //   ),
            // ),
            // Text('Running on: $_platformVersion\n'),
          ],
        ),
      ),
    );
  }
}
