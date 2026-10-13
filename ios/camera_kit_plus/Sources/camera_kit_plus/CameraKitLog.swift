import Foundation

/// Console diagnostics for Camera Kit. Off until the host calls `setSilentLogs`.
enum CameraKitLog {
    static var silent = true

    /// Prints [message] when diagnostics are enabled.
    static func line(_ message: Any) {
        if silent { return }
        Swift.print(message)
    }
}
