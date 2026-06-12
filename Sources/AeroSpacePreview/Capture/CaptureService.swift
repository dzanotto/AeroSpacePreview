import CoreGraphics
import ScreenCaptureKit

/// One-shot window thumbnail capture via ScreenCaptureKit.
struct CaptureService: Sendable {
    var perWindowTimeout: Duration = .milliseconds(250)

    /// Captures a downscaled frame of each requested window concurrently.
    /// Windows that are missing from shareable content, time out, or fail are
    /// simply absent from the result — callers render placeholders for them.
    func thumbnails(for windowIDs: [CGWindowID], maxPixel: Int) async -> [CGWindowID: CGImage] {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [:] }
        let scWindows = Dictionary(
            content.windows.map { ($0.windowID, UncheckedSendable($0)) },
            uniquingKeysWith: { first, _ in first }
        )

        let timeout = perWindowTimeout
        return await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for id in windowIDs {
                guard let boxed = scWindows[id] else { continue }
                group.addTask {
                    let image = try? await withTimeout(timeout) {
                        try await Self.capture(boxed.value, maxPixel: maxPixel)
                    }
                    return (id, image)
                }
            }
            var result: [CGWindowID: CGImage] = [:]
            for await (id, image) in group {
                if let image { result[id] = image }
            }
            return result
        }
    }

    /// The first ScreenCaptureKit capture of a process pays a ~370 ms session
    /// warm-up (measured in M0); do it at launch so the first summon doesn't.
    /// On first run this also triggers the Screen Recording permission prompt.
    func warmUp() async {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true),
            let window = content.windows.first else { return }
        _ = try? await Self.capture(window, maxPixel: 8)
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

/// SCWindow isn't marked Sendable but is an immutable snapshot handle; safe to
/// move into capture tasks.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
