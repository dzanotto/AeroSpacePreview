import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

final class LiveStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
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

        guard LiveThumbnailCoordinator.shouldPublish(frameStatus: status) else {
            if let diagnosticsStatus = LiveThumbnailCoordinator.diagnosticsStatus(frameStatus: status) {
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
        let timing = LiveThumbnailCoordinator.diagnosticsStatus(frameStatus: status).flatMap {
            diagnosticsStatus in
            diagnostics?.recordFrame(
                windowID: windowID,
                status: diagnosticsStatus,
                width: width,
                height: height,
                windowServerDisplayMachTime: Self.displayTime(in: attachments)
            )
        }
        guard let pixelBuffer, let width, let height else { return }

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
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
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

private struct PendingLiveFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    let diagnosticsTiming: DiagnosticsFrameTiming?
}
