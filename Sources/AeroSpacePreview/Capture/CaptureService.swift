import CoreGraphics
import ScreenCaptureKit

/// One-shot window thumbnail capture via ScreenCaptureKit.
struct CaptureService: Sendable {
    /// Generous: the overlay never blocks on a capture (placeholders fill in),
    /// so the timeout only decides when to give up on a stuck window. M6
    /// measurement: 250 ms was tight enough that the back of a 9-window queue
    /// timed out spuriously.
    var perWindowTimeout: Duration = .milliseconds(600)
    /// SCK serializes much of the capture work internally; with many windows
    /// in flight at once, every capture's wall clock inflates (the timeout
    /// timer ticks while the capture waits its turn) and per-window timeouts
    /// fire spuriously. Keeping the in-flight count small makes the timeout
    /// mean "this window is slow", not "the queue is long" — and costs no
    /// throughput, since SCK serializes anyway (~30 ms/window regardless).
    var maxConcurrentCaptures = 4

    /// Captures a downscaled frame of each requested window concurrently,
    /// yielding each thumbnail as soon as its capture completes (captures
    /// begin eagerly, before the stream is consumed). Windows that are
    /// missing from shareable content, time out, or fail are simply never
    /// yielded — callers render placeholders for them.
    func thumbnailStream(for windowIDs: [CGWindowID], maxPixel: Int) -> AsyncStream<(CGWindowID, CGImage)> {
        let timeout = perWindowTimeout
        let maxConcurrent = maxConcurrentCaptures
        return AsyncStream { continuation in
            let task = Task {
                defer { continuation.finish() }
                guard let content = try? await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
                let scWindows = Dictionary(
                    content.windows.map { ($0.windowID, UncheckedSendable($0)) },
                    uniquingKeysWith: { first, _ in first }
                )
                let targets = windowIDs.compactMap { id in scWindows[id].map { (id, $0) } }

                await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                    let capture = { @Sendable (id: CGWindowID, boxed: UncheckedSendable<SCWindow>) async -> (CGWindowID, CGImage?) in
                        let image = try? await withTimeout(timeout) {
                            try await Self.capture(boxed.value, maxPixel: maxPixel)
                        }
                        return (id, image)
                    }

                    var next = 0
                    while next < min(maxConcurrent, targets.count) {
                        let (id, boxed) = targets[next]
                        group.addTask { await capture(id, boxed) }
                        next += 1
                    }
                    for await (id, image) in group {
                        if let image { continuation.yield((id, image)) }
                        if next < targets.count {
                            let (id, boxed) = targets[next]
                            group.addTask { await capture(id, boxed) }
                            next += 1
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Batch variant: all thumbnails at once (used by `--dump-images`).
    func thumbnails(for windowIDs: [CGWindowID], maxPixel: Int) async -> [CGWindowID: CGImage] {
        var result: [CGWindowID: CGImage] = [:]
        for await (id, image) in thumbnailStream(for: windowIDs, maxPixel: maxPixel) {
            result[id] = image
        }
        return result
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
