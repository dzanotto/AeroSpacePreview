import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Starts and owns the ScreenCaptureKit streams that supply change-aware live
/// thumbnails for one overlay summon.
struct LiveThumbnailCoordinator: Sendable {
    typealias StopOperation = @Sendable () async -> Void

    struct Target: Sendable {
        let windowID: CGWindowID
        let start: @Sendable (
            _ maxPixel: Int,
            _ framesPerSecond: Int,
            _ delivery: LiveFrameDelivery,
            _ diagnostics: CaptureDiagnostics?
        ) async throws -> StopOperation
    }

    /// ScreenCaptureKit's documented minimum queue depth.
    static let streamQueueDepth = 3

    private let loadTargets: @Sendable (Set<CGWindowID>) async throws -> [Target]

    init() {
        loadTargets = Self.loadScreenCaptureKitTargets
    }

    init(
        loadTargets: @escaping @Sendable (Set<CGWindowID>) async throws -> [Target]
    ) {
        self.loadTargets = loadTargets
    }

    /// Keeps one change-aware ScreenCaptureKit stream open per window. SCK
    /// emits complete frames when pixels change and idle frames otherwise;
    /// only displayable changed frames reach the caller, so static thumbnails
    /// retain their one-shot image while animation can update at up to 30 fps.
    func start(
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
            let targets: [Target]
            do {
                targets = try await loadTargets(Set(windowIDs))
            } catch {
                if let startupToken { diagnostics?.endLiveStreamStartup(startupToken) }
                return
            }

            let stopOperations = await withTaskGroup(
                of: StopOperation?.self,
                returning: [StopOperation].self
            ) { group in
                for target in targets {
                    let windowID = target.windowID
                    group.addTask {
                        do {
                            let stop = try await target.start(
                                maxPixel,
                                framesPerSecond,
                                delivery,
                                diagnostics
                            )
                            diagnostics?.recordStreamStarted(windowID: windowID)
                            return stop
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

                var result: [StopOperation] = []
                for await stop in group {
                    if let stop { result.append(stop) }
                }
                return result
            }
            if let startupToken { diagnostics?.endLiveStreamStartup(startupToken) }

            await lifetime.install(stopOperations)

            guard !stopOperations.isEmpty, !Task.isCancelled else {
                await lifetime.stop()
                return
            }

            NSLog(
                "AeroSpacePreview: live capture — %ld/%ld streams at up to %ld fps",
                stopOperations.count,
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

    private static func loadScreenCaptureKitTargets(
        _ wanted: Set<CGWindowID>
    ) async throws -> [Target] {
        let content = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.windows.compactMap { window in
            guard wanted.contains(window.windowID) else { return nil }
            let boxed = UncheckedLiveWindow(window)
            return Target(windowID: window.windowID) {
                maxPixel,
                framesPerSecond,
                delivery,
                diagnostics in
                let handle = try await Self.startStream(
                    for: boxed.value,
                    maxPixel: maxPixel,
                    framesPerSecond: framesPerSecond,
                    delivery: delivery,
                    diagnostics: diagnostics
                )
                return {
                    handle.output.stop()
                    try? await handle.stream.stopCapture()
                }
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

    private static func startStream(
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
        config.queueDepth = Self.streamQueueDepth
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

/// SCStream and its callback object have an explicit shared lifecycle. The
/// pair is only accessed through ScreenCaptureKit's thread-safe APIs.
private struct LiveStreamHandle: @unchecked Sendable {
    let stream: SCStream
    let output: LiveStreamOutput
}

/// SCWindow is an immutable snapshot handle but is not marked Sendable by
/// ScreenCaptureKit.
private struct UncheckedLiveWindow: @unchecked Sendable {
    let value: SCWindow
    init(_ value: SCWindow) { self.value = value }
}
