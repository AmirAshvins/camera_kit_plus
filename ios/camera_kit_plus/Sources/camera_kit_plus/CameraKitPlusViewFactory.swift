import Flutter
import UIKit

/// Creates barcode/QR platform views for Flutter.
class CameraKitPlusViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return CameraKitPlusView(frame: frame, viewIdentifier: viewId, arguments: args, binaryMessenger: messenger)
    }
}
