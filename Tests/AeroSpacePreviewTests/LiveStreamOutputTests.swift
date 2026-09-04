import CoreGraphics
import CoreVideo
import Darwin
import os
import ScreenCaptureKit
import Testing
@testable import AeroSpacePreview

@Suite struct LiveStreamOutputTests {
    @Test func readsStatusAndDisplayTimeFromFrameAttachments() {
        let attachments: [SCStreamFrameInfo: Any] = [
            .status: Int(SCFrameStatus.complete.rawValue),
            .displayTime: NSNumber(value: UInt64(123_456)),
        ]

        #expect(LiveStreamOutput.frameStatus(in: attachments) == .complete)
        #expect(LiveStreamOutput.displayTime(in: attachments) == 123_456)
        #expect(LiveStreamOutput.frameStatus(in: [:]) == nil)
        #expect(LiveStreamOutput.displayTime(in: [:]) == nil)
    }

    @Test func idleFrameRecordsDiagnosticsWithoutConversionOrPublication() async throws {
        let diagnostics = CaptureDiagnostics()
        diagnostics.prepareSummon(windowIDs: [101])
        let start = mach_absolute_time()
        diagnostics.beginSession(windowLabels: [101: "Editor"], now: start)
        let delivery = LiveFrameDelivery(diagnostics: diagnostics)
        let conversionCount = LockedIntCounter()
        let output = LiveStreamOutput(
            windowID: 101,
            delivery: delivery,
            diagnostics: diagnostics,
            imageConverter: { _, _ in
                conversionCount.increment()
                return nil
            }
        )

        output.process(frameStatus: .idle, pixelBuffer: nil, displayTime: 99)
        output.stop()
        delivery.finish()

        let snapshot = try #require(diagnostics.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(snapshot.capture.statusCounts.idle == 1)
        #expect(snapshot.capture.changedFrames == 0)
        #expect(snapshot.conversion.framesEntered == 0)
        #expect(conversionCount.value == 0)
        #expect(await delivery.next() == nil)
    }

    @Test func completeFrameConvertsAndPublishesItsDimensions() async throws {
        let pixelBuffer = try #require(makePixelBuffer(width: 14, height: 9))
        let delivery = LiveFrameDelivery(diagnostics: nil)
        let output = LiveStreamOutput(
            windowID: 101,
            delivery: delivery,
            diagnostics: nil,
            imageConverter: { _, bounds in
                makeImage(width: Int(bounds.width), height: Int(bounds.height))
            }
        )

        output.process(frameStatus: .complete, pixelBuffer: pixelBuffer, displayTime: nil)
        let frame = try #require(await delivery.next())

        #expect(frame.windowID == 101)
        #expect(frame.image.width == 14)
        #expect(frame.image.height == 9)
        output.stop()
        delivery.finish()
    }

    @Test func rapidFramesReplacePendingConversionWork() async throws {
        let diagnostics = CaptureDiagnostics()
        diagnostics.prepareSummon(windowIDs: [101])
        let start = mach_absolute_time()
        diagnostics.beginSession(windowLabels: [101: "Editor"], now: start)
        let delivery = LiveFrameDelivery(diagnostics: diagnostics)
        let converter = BlockingImageConverter()
        let output = LiveStreamOutput(
            windowID: 101,
            delivery: delivery,
            diagnostics: diagnostics,
            imageConverter: converter.convert
        )
        let first = try #require(makePixelBuffer(width: 8, height: 8))
        let stale = try #require(makePixelBuffer(width: 16, height: 16))
        let newest = try #require(makePixelBuffer(width: 24, height: 24))

        output.process(frameStatus: .complete, pixelBuffer: first, displayTime: nil)
        #expect(converter.waitUntilFirstConversionStarts())
        output.process(frameStatus: .complete, pixelBuffer: stale, displayTime: nil)
        output.process(frameStatus: .complete, pixelBuffer: newest, displayTime: nil)
        converter.releaseFirstConversion()
        #expect(converter.waitForCompletedConversions(2))

        var snapshot: DiagnosticsSnapshot?
        for _ in 0..<1_000 {
            snapshot = diagnostics.makeSnapshot(
                now: start + DiagnosticsMachClock.ticks(seconds: 1)
            )
            if snapshot?.conversion.successful == 2,
               snapshot?.delivery.droppedOrCoalescedFrames == 2 {
                break
            }
            await Task.yield()
        }

        let finalSnapshot = try #require(snapshot)
        try #require(finalSnapshot.delivery.droppedOrCoalescedFrames == 2)
        let deliveredFrame = try #require(await delivery.next())
        #expect(converter.convertedWidths == [8, 24])
        #expect(deliveredFrame.image.width == 24)
        #expect(finalSnapshot.capture.changedFrames == 3)
        #expect(finalSnapshot.conversion.framesEntered == 2)
        #expect(finalSnapshot.conversion.successful == 2)
        output.stop()
        delivery.finish()
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        return status == kCVReturnSuccess ? pixelBuffer : nil
    }
}

private func makeImage(width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0 else { return nil }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    return CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    )?.makeImage()
}

private final class LockedIntCounter: @unchecked Sendable {
    private let lockedValue = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        lockedValue.withLock { $0 }
    }

    func increment() {
        lockedValue.withLock { $0 += 1 }
    }
}

private final class BlockingImageConverter: @unchecked Sendable {
    private let firstStarted = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let completed = DispatchSemaphore(value: 0)
    private let lockedWidths = OSAllocatedUnfairLock(initialState: [Int]())

    var convertedWidths: [Int] {
        lockedWidths.withLock { $0 }
    }

    func convert(_ pixelBuffer: CVPixelBuffer, _ bounds: CGRect) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let invocation = lockedWidths.withLock { widths in
            widths.append(width)
            return widths.count
        }
        if invocation == 1 {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 2)
        }
        defer { completed.signal() }
        return makeImage(width: Int(bounds.width), height: Int(bounds.height))
    }

    func waitUntilFirstConversionStarts() -> Bool {
        firstStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstConversion() {
        releaseFirst.signal()
    }

    func waitForCompletedConversions(_ count: Int) -> Bool {
        for _ in 0..<count where completed.wait(timeout: .now() + 2) != .success {
            return false
        }
        return true
    }
}
