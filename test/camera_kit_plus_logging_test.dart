import 'package:camera_kit_plus/camera_kit_plus_logging.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    CameraKitPlusLogging.configure(silentLogs: true);
  });

  test('camera logs are silent by default', () {
    expect(CameraKitPlusLogging.silentLogs, isTrue);
    CameraKitPlusLogging.configure(silentLogs: true);
    expect(CameraKitPlusLogging.silentLogs, isTrue);
  });

  test('configure can enable camera diagnostics', () {
    CameraKitPlusLogging.configure(silentLogs: false);
    expect(CameraKitPlusLogging.silentLogs, isFalse);
  });
}
