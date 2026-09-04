import 'package:flutter_test/flutter_test.dart';
import 'package:camera_kit_plus/camera_kit_plus.dart';
import 'package:camera_kit_plus/camera_kit_plus_platform_interface.dart';
import 'package:camera_kit_plus/camera_kit_plus_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockCameraKitPlusPlatform
    with MockPlatformInterfaceMixin
    implements CameraKitPlusPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool> getCameraPermission() => Future.value(true);
}

void main() {
  final CameraKitPlusPlatform initialPlatform = CameraKitPlusPlatform.instance;

  test('$MethodChannelCameraKitPlus is the default instance', () {
    expect(initialPlatform, isA<MethodChannelCameraKitPlus>());
  });

  test('getPlatformVersion', () async {
    final plugin = CameraKitPlus();
    final fakePlatform = MockCameraKitPlusPlatform();
    CameraKitPlusPlatform.instance = fakePlatform;
    expect(await plugin.getPlatformVersion(), '42');
  });

  test('getCameraPermission', () async {
    final plugin = CameraKitPlus();
    final fakePlatform = MockCameraKitPlusPlatform();
    CameraKitPlusPlatform.instance = fakePlatform;
    expect(await plugin.getCameraPermission(), isTrue);
  });

  test('OcrData JSON round-trip', () {
    final data = OcrData(
      text: 'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<',
      path: '',
      orientation: 1,
      lines: [
        OcrLine(
          text: 'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<',
          cornerPoints: [OcrPoint(x: 1, y: 2), OcrPoint(x: 3, y: 4)],
        ),
      ],
    );
    final parsed = OcrData.fromJson(data.toJson());
    expect(parsed.text, data.text);
    expect(parsed.lines.first.cornerPoints.first.x, 1);
  });

  test('BarcodeData JSON parse', () {
    final data = BarcodeData.fromJson({
      'value': 'ABC123',
      'type': 1,
      'cornerPoints': [
        {'x': 0.0, 'y': 0.0},
        {'x': 1.0, 'y': 1.0},
      ],
    });
    expect(data.value, 'ABC123');
    expect(data.cornerPoints.length, 2);
  });
}
