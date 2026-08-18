import CoreGraphics
import ScreenCaptureKit

/// Window frames + display bounds from one SCShareableContent lookup, in
/// global top-left-origin coordinates: the raw material for layout caching.
/// Frames are only meaningful for windows currently on a visible workspace;
/// hidden ones are stacked off-viewport.
struct WindowFrameHarvest: Sendable {
    let frames: [CGWindowID: CGRect]
    let displays: [CGRect]
}

enum CaptureEvent: Sendable {
    /// Always the first event: the frames of every requested window present
    /// in shareable content, delivered before any pixels so layout rendering
    /// never waits on captures.
    case frames(WindowFrameHarvest)
    case desktopBackground(CGImage)
    case thumbnail(CGWindowID, CGImage)
}

/// One-shot window, wallpaper, geometry, and warm-up capture via
/// ScreenCaptureKit. Wallpaper work stays in the same bounded batch so it can
/// reuse the shareable-content lookup and participate in the same concurrency
/// budget as window screenshots.
struct OneShotCaptureService: Sendable {
    /// Best-effort deadline: `SCScreenshotManager.captureImage` has no supported
    /// cancellation control, so a timed-out structured child may still delay task
    /// completion while ScreenCaptureKit winds down. Overlay presentation does not
    /// wait for captures; placeholders fill in. A 250 ms limit was observed to make
    /// the back of a 9-window queue time out spuriously.
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
    /// captures need anyway. When a display is supplied, a desktop-background
    /// still is captured in the same bounded batch and yielded as soon as it
    /// arrives. Windows that are missing from shareable content, time out, or
    /// fail are simply never yielded — callers render placeholders.
    func captureStream(
        for windowIDs: [CGWindowID],
        maxPixel: Int,
        desktopDisplayID: CGDirectDisplayID? = nil,
        desktopMaxPixel: Int = 2560
    ) -> AsyncStream<CaptureEvent> {
        let timeout = perWindowTimeout
        let maximumConcurrentTasks = maxConcurrentCaptures
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

                var jobs: [OneShotCaptureJob] = []
                if let desktopDisplayID {
                    let boxedContent = UncheckedSendable(content)
                    jobs.append(OneShotCaptureJob {
                        let image = try? await withTimeout(timeout) {
                            await Self.captureDesktopBackground(
                                from: boxedContent.value,
                                displayID: desktopDisplayID,
                                maxPixel: desktopMaxPixel
                            )
                        }
                        return .desktopBackground(image)
                    })
                }
                jobs.append(contentsOf: targets.map { id, boxed in
                    OneShotCaptureJob {
                        let image = try? await withTimeout(timeout) {
                            try await Self.capture(boxed.value, maxPixel: maxPixel)
                        }
                        return .thumbnail(id, image)
                    }
                })

                let batch = BoundedAsyncBatch(
                    elements: jobs,
                    maximumConcurrentTasks: maximumConcurrentTasks,
                    operation: { await $0.run() }
                )
                await batch.run { result in
                    switch result {
                    case .desktopBackground(let image):
                        if let image { continuation.yield(.desktopBackground(image)) }
                    case .thumbnail(let id, let image):
                        if let image { continuation.yield(.thumbnail(id, image)) }
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
    /// by the post-switch background harvest, which needs the newly visible
    /// workspace's window frames but no thumbnails.
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
    /// warm-up; do it at launch so the first summon does not pay it.
    /// On first run this also triggers the Screen Recording permission prompt.
    func warmUp() async {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true),
            let window = content.windows.first else { return }
        _ = try? await Self.capture(window, maxPixel: 8)
    }

    /// Wallpaper is exposed as a full-display Dock window on current macOS.
    /// Selecting it directly avoids reproducing the menu bar, Dock, or Finder
    /// desktop icons. The display-filter path below is the supported fallback
    /// if that window-server convention changes.
    static func isWallpaperWindow(
        bundleIdentifier: String?,
        title: String?,
        frame: CGRect,
        displayFrame: CGRect
    ) -> Bool {
        guard bundleIdentifier == "com.apple.dock",
              title?.hasPrefix("Wallpaper") == true else { return false }
        let tolerance: CGFloat = 1
        return abs(frame.minX - displayFrame.minX) <= tolerance
            && abs(frame.minY - displayFrame.minY) <= tolerance
            && abs(frame.width - displayFrame.width) <= tolerance
            && abs(frame.height - displayFrame.height) <= tolerance
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
            isWallpaperWindow(
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

private struct OneShotCaptureJob: Sendable {
    let run: @Sendable () async -> OneShotCaptureResult

    init(_ run: @escaping @Sendable () async -> OneShotCaptureResult) {
        self.run = run
    }
}

private enum OneShotCaptureResult: Sendable {
    case desktopBackground(CGImage?)
    case thumbnail(CGWindowID, CGImage?)
}

/// SCWindow and SCShareableContent are immutable snapshot handles but are not
/// marked Sendable by ScreenCaptureKit.
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
