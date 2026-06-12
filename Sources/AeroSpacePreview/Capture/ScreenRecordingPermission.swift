import AppKit
import CoreGraphics

/// Screen Recording (TCC) permission state. Thumbnails require it; the
/// overlay degrades to placeholder cards without it.
enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt on first call; afterwards macOS requires the
    /// user to flip the toggle in System Settings manually.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openSystemSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
