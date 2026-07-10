import CoreImage
import CoreGraphics
import CoreMedia
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

struct LiveThumbnailFrame: Sendable {
    let windowID: CGWindowID
    let image: CGImage
}

/// One-shot and change-aware live window capture via ScreenCaptureKit.
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

    /// Keeps one change-aware ScreenCaptureKit stream open per window. SCK
    /// emits complete frames when pixels change and idle frames otherwise;
    /// only displayable changed frames reach the caller, so static thumbnails
    /// retain their one-shot image while animation can update at up to 30 fps.
    func liveThumbnailStream(
        for windowIDs: [CGWindowID],
        maxPixel: Int,
        framesPerSecond: Int = 30
    ) -> AsyncStream<LiveThumbnailFrame> {
        AsyncStream { continuation in
            let lifetime = LiveStreamLifetime()
            let task = Task {
                defer { continuation.finish() }
                guard !windowIDs.isEmpty,
                      let content = try? await SCShareableContent
                        .excludingDesktopWindows(false, onScreenWindowsOnly: false)
                else { return }

                let wanted = Set(windowIDs)
                let targets = content.windows.filter { wanted.contains($0.windowID) }
                let handles = await withTaskGroup(
                    of: LiveStreamHandle?.self,
                    returning: [LiveStreamHandle].self
                ) { group in
                    for window in targets {
                        let windowID = window.windowID
                        let boxed = UncheckedSendable(window)
                        group.addTask {
                            do {
                                return try await Self.startLiveStream(
                                    for: boxed.value,
                                    maxPixel: maxPixel,
                                    framesPerSecond: framesPerSecond,
                                    continuation: continuation
                                )
                            } catch {
                                NSLog(
                                    "AeroSpacePreview: live capture failed to start for window %u: %@",
                                    windowID,
                                    String(describing: error)
                                )
                                return nil
                            }
                        }
                    }

                    var result: [LiveStreamHandle] = []
                    for await handle in group {
                        if let handle { result.append(handle) }
                    }
                    return result
                }

                await lifetime.install(handles.map { handle in
                    { try? await handle.stream.stopCapture() }
                })

                guard !handles.isEmpty, !Task.isCancelled else {
                    await lifetime.stop()
                    return
                }

                NSLog(
                    "AeroSpacePreview: live capture — %ld/%ld streams at up to %ld fps",
                    handles.count,
                    targets.count,
                    framesPerSecond
                )

                do {
                    // AsyncStream termination cancels this task. Sleeping
                    // avoids polling while the output callbacks yield frames.
                    try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
                } catch {
                    // Cancellation is the normal dismissal path.
                }
                await lifetime.stop()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await lifetime.stop() }
            }
        }
    }

    static func shouldPublish(frameStatus: SCFrameStatus) -> Bool {
        switch frameStatus {
        case .started, .complete:
            true
        case .idle, .blank, .suspended, .stopped:
            false
        @unknown default:
            false
        }
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

    private static func startLiveStream(
        for window: SCWindow,
        maxPixel: Int,
        framesPerSecond: Int,
        continuation: AsyncStream<LiveThumbnailFrame>.Continuation
    ) async throws -> LiveStreamHandle {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let size = window.frame.size
        let scale = min(1.0, CGFloat(maxPixel) / max(size.width, size.height, 1))
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, framesPerSecond))
        )
        config.queueDepth = 2
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false

        let output = LiveStreamOutput(windowID: window.windowID, continuation: continuation)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: output.queue
        )
        try await stream.startCapture()
        return LiveStreamHandle(stream: stream, output: output)
    }
}

private final class LiveStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// Serial per window preserves frame order; separate window queues still
    /// let unrelated animated windows convert frames concurrently.
    let queue: DispatchQueue
    private let windowID: CGWindowID
    private let continuation: AsyncStream<LiveThumbnailFrame>.Continuation

    init(
        windowID: CGWindowID,
        continuation: AsyncStream<LiveThumbnailFrame>.Continuation
    ) {
        self.windowID = windowID
        self.continuation = continuation
        queue = DispatchQueue(
            label: "com.dariozanotto.aerospacepreview.live-capture.\(windowID)",
            qos: .userInteractive
        )
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let status = Self.frameStatus(of: sampleBuffer),
              CaptureService.shouldPublish(frameStatus: status),
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let image = Self.imageContext.createCGImage(
            CIImage(cvPixelBuffer: pixelBuffer),
            from: bounds
        ) else { return }
        continuation.yield(LiveThumbnailFrame(windowID: windowID, image: image))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        NSLog(
            "AeroSpacePreview: live capture stopped for window %u: %@",
            windowID,
            String(describing: error)
        )
    }

    private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawValue = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: rawValue)
    }
}

/// SCStream and its callback object have an explicit shared lifecycle. The
/// pair is only accessed through ScreenCaptureKit's thread-safe APIs.
private struct LiveStreamHandle: @unchecked Sendable {
    let stream: SCStream
    let output: LiveStreamOutput
}

/// Idempotent cleanup for a group of streams. If cancellation wins the race
/// with asynchronous startup, later-installed streams are stopped immediately.
actor LiveStreamLifetime {
    typealias StopOperation = @Sendable () async -> Void

    private var stopOperations: [StopOperation] = []
    private var isStopped = false

    func install(_ operations: [StopOperation]) async {
        guard !isStopped else {
            await Self.run(operations)
            return
        }
        stopOperations.append(contentsOf: operations)
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        let operations = stopOperations
        stopOperations.removeAll()
        await Self.run(operations)
    }

    private static func run(_ operations: [StopOperation]) async {
        await withTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask { await operation() }
            }
        }
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
