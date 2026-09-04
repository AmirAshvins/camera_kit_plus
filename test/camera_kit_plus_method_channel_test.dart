import 'package:camera_kit_plus/camera_kit_plus_controller.dart';
import 'package:camera_kit_plus/camera_kit_plus_method_channel.dart';
import 'package:camera_kit_plus/enums.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('plugin channel', () {
    final platform = MethodChannelCameraKitPlus();
    const channel = MethodChannel('camera_kit_plus');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getPlatformVersion':
            return '42';
          case 'getCameraPermission':
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('getPlatformVersion', () async {
      expect(await platform.getPlatformVersion(), '42');
    });

    test('getCameraPermission', () async {
      expect(await platform.getCameraPermission(), isTrue);
    });
  });

  group('per-view controller channel', () {
    late CameraKitPlusController controller;
    const viewChannel = MethodChannel('camera_kit_plus/view_7');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      controller = CameraKitPlusController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(viewChannel, (call) async {
        calls.add(call);
        if (call.method == 'takePicture') return '/tmp/a.jpg';
        return true;
      });
      controller.bindToView(7);
    });

    tearDown(() {
      controller.unbind();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(viewChannel, null);
    });

    test('pauseCamera goes to view channel', () async {
      expect(await controller.pauseCamera(), isTrue);
      expect(calls.single.method, 'pauseCamera');
    });

    test('changeFlashMode sends flashModeID', () async {
      await controller.changeFlashMode(CameraKitPlusFlashMode.on);
      expect(calls.single.method, 'changeFlashMode');
      expect((calls.single.arguments as Map)['flashModeID'], 1);
    });

    test('takePicture returns path', () async {
      expect(await controller.takePicture(), '/tmp/a.jpg');
    });

    test('unbound controller returns false/null', () async {
      controller.unbind();
      expect(await controller.pauseCamera(), isFalse);
      expect(await controller.takePicture(), isNull);
    });
  });
}
