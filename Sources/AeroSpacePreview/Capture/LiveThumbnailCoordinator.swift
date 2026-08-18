import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Starts and owns the ScreenCaptureKit streams that supply change-aware live
/// thumbnails for one overlay summon.
struct LiveThumbnailCoordinator: Sendable {
    /// ScreenCaptureKit's documented minimum queue depth.
    static let streamQueueDepth = 3

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
                    let boxed = UncheckedLiveWindow(window)
                    group.addTask {
                        do {
                            let handle = try await Self.startStream(
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
