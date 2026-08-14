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
    case desktopBackground(CGImage)
    case thumbnail(CGWindowID, CGImage)
}

struct LiveThumbnailFrame: Sendable {
    let windowID: CGWindowID
    let image: CGImage
    let diagnosticsTiming: DiagnosticsFrameTiming?
}

/// One-shot and change-aware live window capture via ScreenCaptureKit.
struct CaptureService: Sendable {
    /// ScreenCaptureKit's documented minimum queue depth.
    static let liveStreamQueueDepth = 3

    /// Best-effort deadline: `SCScreenshotManager.captureImage` has no supported
    /// cancellation control, so a timed-out structured child may still delay task
    /// completion while ScreenCaptureKit winds down. Overlay presentation does not
    /// wait for captures; placeholders fill in. M6 measurement found 250 ms tight
    /// enough for the back of a 9-window queue to time out spuriously.
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
    /// still is captured in the same bounded task group and yielded as soon as
    /// it arrives. Windows that are missing from shareable content, time out,
    /// or fail are simply never yielded — callers render placeholders.
    func captureStream(
        for windowIDs: [CGWindowID],
        maxPixel: Int,
        desktopDisplayID: CGDirectDisplayID? = nil,
        desktopMaxPixel: Int = 2560
    ) -> AsyncStream<CaptureEvent> {
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

                await withTaskGroup(of: OneShotCaptureResult.self) { group in
                    if let desktopDisplayID {
                        let boxedContent = UncheckedSendable(content)
                        group.addTask {
                            let image = try? await withTimeout(timeout) {
                                await Self.captureDesktopBackground(
                                    from: boxedContent.value,
                                    displayID: desktopDisplayID,
                                    maxPixel: desktopMaxPixel
                                )
                            }
                            return .desktopBackground(image)
                        }
                    }

                    let capture = { @Sendable (id: CGWindowID, boxed: UncheckedSendable<SCWindow>) async -> OneShotCaptureResult in
                        let image = try? await withTimeout(timeout) {
                            try await Self.capture(boxed.value, maxPixel: maxPixel)
                        }
                        return .thumbnail(id, image)
                    }

                    let availableSlots = max(1, maxConcurrent)
                        - (desktopDisplayID == nil ? 0 : 1)
                    var next = 0
                    while next < min(max(0, availableSlots), targets.count) {
                        let (id, boxed) = targets[next]
                        group.addTask { await capture(id, boxed) }
                        next += 1
                    }
                    for await result in group {
                        switch result {
                        case .desktopBackground(let image):
                            if let image { continuation.yield(.desktopBackground(image)) }
                        case .thumbnail(let id, let image):
                            if let image { continuation.yield(.thumbnail(id, image)) }
                        }
                        if next < targets.count {
                            let (nextID, boxed) = targets[next]
                            group.addTask { await capture(nextID, boxed) }
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
    func startLiveThumbnailCapture(
        for windowIDs: [CGWindowID],
        maxPixel: Int,
        framesPerSecond: Int = 30,
        diagnostics: CaptureDiagnostics? = nil
    ) -> LiveThumbnailCapture {
        let delivery = LiveFrameDelivery(diagnostics: diagnostics)
        let lifetime = LiveStreamLifetime()
        let task = Task {
            defer { delivery.finish() }
            guard !windowIDs.isEmpty else { return }
            let startupToken = diagnostics?.beginLiveStreamStartup()
            guard let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else {
                if let startupToken { diagnostics?.endLiveStreamStartup(startupToken) }
                return
            }

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
                            let handle = try await Self.startLiveStream(
                                for: boxed.value,
                                maxPixel: maxPixel,
                                framesPerSecond: framesPerSecond,
                                delivery: delivery,
                                diagnostics: diagnostics
                            )
                            diagnostics?.recordStreamStarted(windowID: windowID)
                            return handle
                        } catch {
                            diagnostics?.recordStreamStartupFailure(windowID: windowID)
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
            if let startupToken { diagnostics?.endLiveStreamStartup(startupToken) }

            await lifetime.install(handles.map { handle in
                {
                    handle.output.stop()
                    try? await handle.stream.stopCapture()
                }
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
                // AsyncStream cancellation cancels this task. Sleeping avoids
                // polling while the output callbacks publish keyed frames.
                try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
            } catch {
                // Cancellation is the normal dismissal path.
            }
            await lifetime.stop()
        }
        let stop: @Sendable () -> Void = {
            task.cancel()
            delivery.finish()
            Task { await lifetime.stop() }
        }
        return LiveThumbnailCapture(
            next: { await delivery.next() },
            stopOperation: stop
        )
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

    static func diagnosticsStatus(frameStatus: SCFrameStatus) -> DiagnosticsFrameStatus? {
        switch frameStatus {
        case .started: .started
        case .complete: .complete
        case .idle: .idle
        case .blank: .blank
        case .suspended: .suspended
        case .stopped: .stopped
        @unknown default: nil
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

    private static func startLiveStream(
        for window: SCWindow,
        maxPixel: Int,
        framesPerSecond: Int,
        delivery: LiveFrameDelivery,
        diagnostics: CaptureDiagnostics?
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
        config.queueDepth = liveStreamQueueDepth
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false

        let output = LiveStreamOutput(
            windowID: window.windowID,
            delivery: delivery,
            diagnostics: diagnostics
        )
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

    /// ScreenCaptureKit intake stays unblocked while the separate serial
    /// conversion queue drains at most one active and one pending frame.
    let queue: DispatchQueue
    private let conversionQueue: DispatchQueue
    private let windowID: CGWindowID
    private let delivery: LiveFrameDelivery
    private let diagnostics: CaptureDiagnostics?
    private let frameCoalescer = LatestFrameCoalescer<PendingLiveFrame>()

    init(
        windowID: CGWindowID,
        delivery: LiveFrameDelivery,
        diagnostics: CaptureDiagnostics?
    ) {
        self.windowID = windowID
        self.delivery = delivery
        self.diagnostics = diagnostics
        queue = DispatchQueue(
            label: "com.dariozanotto.aerospacepreview.live-capture.\(windowID)",
            qos: .userInteractive
        )
        conversionQueue = DispatchQueue(
            label: "com.dariozanotto.aerospacepreview.live-conversion.\(windowID)",
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
              let attachments = Self.frameAttachments(of: sampleBuffer),
              let status = Self.frameStatus(in: attachments)
        else { return }

        guard CaptureService.shouldPublish(frameStatus: status) else {
            if let diagnosticsStatus = CaptureService.diagnosticsStatus(frameStatus: status) {
                _ = diagnostics?.recordFrame(
                    windowID: windowID,
                    status: diagnosticsStatus,
                    width: nil,
                    height: nil,
                    windowServerDisplayMachTime: nil
                )
            }
            return
        }

        let pixelBuffer = sampleBuffer.imageBuffer
        let width = pixelBuffer.map { CVPixelBufferGetWidth($0) }
        let height = pixelBuffer.map { CVPixelBufferGetHeight($0) }
        let timing = CaptureService.diagnosticsStatus(frameStatus: status).flatMap { diagnosticsStatus in
            diagnostics?.recordFrame(
                windowID: windowID,
                status: diagnosticsStatus,
                width: width,
                height: height,
                windowServerDisplayMachTime: Self.displayTime(in: attachments)
            )
        }
        guard let pixelBuffer,
              let width,
              let height
        else { return }

        let frame = PendingLiveFrame(
            pixelBuffer: pixelBuffer,
            width: width,
            height: height,
            diagnosticsTiming: timing
        )
        let submission = frameCoalescer.submit(frame)
        if let replaced = submission.replacedElement {
            diagnostics?.recordPreConversionCoalesced(timing: replaced.diagnosticsTiming)
        }
        guard submission.shouldStartProcessing else { return }

        conversionQueue.async { [self] in
            drain(startingWith: frame)
        }
    }

    func stop() {
        if let pending = frameCoalescer.stop() {
            diagnostics?.recordPreConversionCoalesced(timing: pending.diagnosticsTiming)
        }
    }

    private func drain(startingWith firstFrame: PendingLiveFrame) {
        var frame: PendingLiveFrame? = firstFrame
        while let current = frame {
            if frameCoalescer.isActive {
                convertAndPublish(current)
            }
            frame = frameCoalescer.next()
        }
    }

    private func convertAndPublish(_ frame: PendingLiveFrame) {
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: frame.width,
            height: frame.height
        )
        let conversionToken = frame.diagnosticsTiming.flatMap {
            diagnostics?.beginConversion(timing: $0)
        }
        let image = Self.imageContext.createCGImage(
            CIImage(cvPixelBuffer: frame.pixelBuffer),
            from: bounds
        )
        if let conversionToken {
            diagnostics?.endConversion(
                conversionToken,
                succeeded: image != nil,
                convertedPixelCount: image.map { UInt64($0.width) * UInt64($0.height) } ?? 0
            )
        }
        guard let image, frameCoalescer.isActive else { return }

        delivery.publish(LiveThumbnailFrame(
            windowID: windowID,
            image: image,
            diagnosticsTiming: frame.diagnosticsTiming
        ))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stop()
        NSLog(
            "AeroSpacePreview: live capture stopped for window %u: %@",
            windowID,
            String(describing: error)
        )
    }

    private static func frameAttachments(
        of sampleBuffer: CMSampleBuffer
    ) -> [SCStreamFrameInfo: Any]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let first = attachments.first
        else { return nil }
        return first
    }

    private static func frameStatus(in attachments: [SCStreamFrameInfo: Any]) -> SCFrameStatus? {
        guard let rawValue = attachments[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: rawValue)
    }

    private static func displayTime(in attachments: [SCStreamFrameInfo: Any]) -> UInt64? {
        if let value = attachments[.displayTime] as? UInt64 { return value }
        return (attachments[.displayTime] as? NSNumber)?.uint64Value
    }

}

private enum OneShotCaptureResult: Sendable {
    case desktopBackground(CGImage?)
    case thumbnail(CGWindowID, CGImage?)
}

private final class LiveFrameDelivery: @unchecked Sendable {
    private let buffer = LatestByKeyBuffer<CGWindowID, LiveThumbnailFrame>()
    private let diagnostics: CaptureDiagnostics?

    init(diagnostics: CaptureDiagnostics?) {
        self.diagnostics = diagnostics
    }

    func publish(_ frame: LiveThumbnailFrame) {
        _ = buffer.submit(frame, for: frame.windowID) { [diagnostics] replaced in
            diagnostics?.recordYielded(
                timing: frame.diagnosticsTiming,
                replacing: replaced?.diagnosticsTiming
            )
        }
    }

    func next() async -> LiveThumbnailFrame? {
        await buffer.next()
    }

    func finish() {
        for frame in buffer.finish() {
            guard let timing = frame.diagnosticsTiming else { continue }
            diagnostics?.recordYieldRejected(timing: timing, droppedOrCoalesced: false)
        }
    }
}

private struct PendingLiveFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    let diagnosticsTiming: DiagnosticsFrameTiming?
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
