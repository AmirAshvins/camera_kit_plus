enum CameraKitPlusFlashMode {
  off,
  on,
  auto
}

enum CameraKitPlusCameraMode {
  back,
  front,

}

enum BarcodeType {
  unknown(0),
  code128(1),
  code39(2),
  code93(4),
  codabar(8),
  dataMatrix(16),
  ean13(32),
  ean8(64),
  itf(128),
  qrCode(256),
  upcA(512),
  upcE(1024),
  pdf417(2048),
  aztec(4096);

  final int code;
  const BarcodeType(this.code);

  // Get enum from code
  static BarcodeType fromCode(int code) {
    return BarcodeType.values.firstWhere(
          (type) => type.code == code,
      orElse: () => BarcodeType.unknown,
    );
  }
}