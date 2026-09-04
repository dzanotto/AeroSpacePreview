import CoreGraphics
import ScreenCaptureKit

/// Testable boundary around ScreenCaptureKit discovery and image capture.
/// Production uses ``screenCaptureKit``; tests supply deterministic windows.
struct OneShotCaptureSource: Sendable {
    struct Window: Sendable {
        let id: CGWindowID
        let frame: CGRect
        let capture: @Sendable (_ maxPixel: Int) async throws -> CGImage
    }

    struct Content: Sendable {
        let windows: [Window]
        let displayFrames: [CGRect]
        let captureDesktop: @Sendable (
            _ displayID: CGDirectDisplayID,
            _ maxPixel: Int
        ) async -> CGImage?
    }

    let load: @Sendable (
        _ excludingDesktopWindows: Bool,
        _ onScreenWindowsOnly: Bool
    ) async throws -> Content

    static let screenCaptureKit = OneShotCaptureSource { excludingDesktopWindows, onScreenWindowsOnly in
        let content = try await SCShareableContent.excludingDesktopWindows(
            excludingDesktopWindows,
            onScreenWindowsOnly: onScreenWindowsOnly
        )
        let boxedContent = UncheckedShareableContent(content)
        return Content(
            windows: content.windows.map { window in
                let boxedWindow = UncheckedCaptureWindow(window)
                return Window(id: window.windowID, frame: window.frame) { maxPixel in
                    try await capture(boxedWindow.value, maxPixel: maxPixel)
                }
            },
            displayFrames: content.displays.map(\.frame),
            captureDesktop: { displayID, maxPixel in
                await captureDesktopBackground(
                    from: boxedContent.value,
                    displayID: displayID,
                    maxPixel: maxPixel
                )
            }
        )
    }

    private static func captureDesktopBackground(
        from content: SCShareableContent,
        displayID: CGDirectDisplayID,
        maxPixel: Int
    ) async -> CGImage? {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return nil
        }
        if let wallpaper = content.windows.first(where: {
            OneShotCaptureService.isWallpaperWindow(
                bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                title: $0.title,
                frame: $0.frame,
                displayFrame: display.frame
            )
        }) {
            return try? await capture(wallpaper, maxPixel: maxPixel)
        }

        // A display-excluding filter always retains the rendered desktop.
        // Asking for content without desktop windows means the exclusion list
        // removes applications (including our panel), but not the wallpaper.
        guard let visibleContent = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let visibleDisplay = visibleContent.displays.first(where: { $0.displayID == displayID })
        else { return nil }

        let filter = SCContentFilter(
            display: visibleDisplay,
            excludingWindows: visibleContent.windows
        )
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = false
        }
        let config = SCStreamConfiguration()
        let width = CGFloat(visibleDisplay.width)
        let height = CGFloat(visibleDisplay.height)
        let scale = min(1.0, CGFloat(maxPixel) / max(width, height, 1))
        config.width = max(1, Int(width * scale))
        config.height = max(1, Int(height * scale))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    private static func capture(_ window: SCWindow, maxPixel: Int) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let size = window.frame.size
        let scale = min(1.0, CGFloat(maxPixel) / max(size.width, size.height, 1))
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// ScreenCaptureKit snapshot handles are immutable but not marked Sendable.
private struct UncheckedCaptureWindow: @unchecked Sendable {
    let value: SCWindow

    init(_ value: SCWindow) {
        self.value = value
    }
}

private struct UncheckedShareableContent: @unchecked Sendable {
    let value: SCShareableContent

    init(_ value: SCShareableContent) {
        self.value = value
    }
}
