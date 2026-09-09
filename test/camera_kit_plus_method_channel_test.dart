import 'package:camera_kit_plus/camera_kit_plus_controller.dart'
    show
        CameraKitPlusController,
        cameraKitPlusAllowsAutoResume,
        cameraKitPlusBindPlatformView;
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

    test('getFlashMode queries native torch', () async {
      expect(await controller.getFlashMode(), isTrue);
      expect(calls.single.method, 'getFlashMode');
    });

    test('takePicture returns path', () async {
      expect(await controller.takePicture(), '/tmp/a.jpg');
    });

    test('unbound controller returns false/null', () async {
      controller.unbind();
      expect(await controller.pauseCamera(), isFalse);
      expect(await controller.takePicture(), isNull);
    });

    test('disposeView invokes native dispose then unbinds', () async {
      await controller.disposeView();
      expect(calls.single.method, 'dispose');
      expect(controller.isBound, isFalse);
      // Further pause after dispose must no-op (channel cleared).
      expect(await controller.pauseCamera(), isFalse);
    });

    test('late platform-view create after widget dispose stops native capture',
        () async {
      // Mirrors CameraKitPlusView.dispose before onPlatformViewCreated:
      // unbind (not bound yet), then a delayed create must still dispose.
      controller.unbind();
      expect(controller.isBound, isFalse);
      calls.clear();
      await cameraKitPlusBindPlatformView(
        controller: controller,
        viewId: 7,
        released: true,
      );
      expect(calls.map((c) => c.method), ['dispose']);
      expect(controller.isBound, isFalse);
    });

    test('late platform-view create while mounted stays bound', () async {
      controller.unbind();
      calls.clear();
      await cameraKitPlusBindPlatformView(
        controller: controller,
        viewId: 7,
        released: false,
      );
      expect(calls, isEmpty);
      expect(controller.isBound, isTrue);
    });

    test('external host can pause then disposeView like widget teardown',
        () async {
      // Mirrors CameraKitPlusView.dispose for host-owned controllers: stop
      // capture via disposeView so the session does not stay armed after unbind.
      expect(await controller.pauseCamera(), isTrue);
      await controller.disposeView();
      expect(calls.map((c) => c.method), ['pauseCamera', 'dispose']);
      expect(controller.isBound, isFalse);
    });

    test('visibility resume is ignored while host-paused', () async {
      expect(await controller.pauseCamera(), isTrue);
      expect(controller.hostPaused, isTrue);
      calls.clear();
      expect(await controller.resumeCamera(host: false), isFalse);
      expect(calls, isEmpty);
      expect(controller.hostPaused, isTrue);
      expect(
        cameraKitPlusAllowsAutoResume(
          hostPaused: controller.hostPaused,
          visibleFraction: 0.2,
        ),
        isFalse,
      );
      expect(
        cameraKitPlusAllowsAutoResume(
          hostPaused: true,
          visibleFraction: 1,
        ),
        isFalse,
      );
      expect(
        cameraKitPlusAllowsAutoResume(
          hostPaused: false,
          visibleFraction: 1,
        ),
        isTrue,
      );
    });
  });
}
