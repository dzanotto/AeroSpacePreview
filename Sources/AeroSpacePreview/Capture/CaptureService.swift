import CoreGraphics
import ScreenCaptureKit

/// Window frames + display bounds from one SCShareableContent lookup, in
/// global top-left-origin coordinates: the raw material for layout caching
/// (M7). Frames are only meaningful for windows currently on a visible
/// workspace — hidden ones are stacked off-viewport.
struct WindowFrameHarvest: Sendable {
    let frames: [CGWindowID: CGRect]
    let displays: [CGRect]
}

enum CaptureEvent: Sendable {
    /// Always the first event: the frames of every requested window present
    /// in shareable content, delivered before any pixels so layout rendering
    /// never waits on captures.
    case frames(WindowFrameHarvest)
    case thumbnail(CGWindowID, CGImage)
}

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
    /// begin eagerly, before the stream is consumed). The first event carries
    /// the windows' frames — piggybacked on the SCShareableContent lookup the
    /// captures need anyway. Windows that are missing from shareable content,
    /// time out, or fail are simply never yielded — callers render
    /// placeholders for them.
    func captureStream(for windowIDs: [CGWindowID], maxPixel: Int) -> AsyncStream<CaptureEvent> {
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

                continuation.yield(.frames(WindowFrameHarvest(
                    frames: Dictionary(uniqueKeysWithValues: targets.map { ($0.0, $0.1.value.frame) }),
                    displays: content.displays.map(\.frame)
                )))

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
                        if let image { continuation.yield(.thumbnail(id, image)) }
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
        for await event in captureStream(for: windowIDs, maxPixel: maxPixel) {
            if case .thumbnail(let id, let image) = event { result[id] = image }
        }
        return result
    }

    /// One shareable-content lookup, frames only — no pixels captured. Used
    /// by the post-switch background harvest (M7), which needs the newly
    /// visible workspace's window frames but no thumbnails.
    func windowFrames(for windowIDs: [CGWindowID]) async -> WindowFrameHarvest? {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        let wanted = Set(windowIDs)
        var frames: [CGWindowID: CGRect] = [:]
        for window in content.windows where wanted.contains(window.windowID) {
            frames[window.windowID] = window.frame
        }
        return WindowFrameHarvest(frames: frames, displays: content.displays.map(\.frame))
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
