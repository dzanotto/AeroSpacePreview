import CoreGraphics

/// Applies asynchronous capture events to one visible overlay session. The
/// controller supplies session validity and background-cache ownership while
/// this type keeps the event semantics independently testable from AppKit.
@MainActor
enum OverlayCaptureConsumer {
    static func consumeOneShotEvents(
        _ stream: AsyncStream<CaptureEvent>,
        content: OverlayContent,
        targetDisplayID: CGDirectDisplayID?,
        viewModel: OverlayViewModel,
        frameCache: FrameCacheStore,
        isCurrent: () -> Bool,
        cacheDesktopBackground: (CGDirectDisplayID, CGImage) -> Void
    ) async -> Int? {
        var captured = 0
        for await event in stream {
            guard !Task.isCancelled, isCurrent() else { return nil }
            switch event {
            case .frames(let harvest):
                // The focused workspace is visible, so its geometry is valid.
                guard case .snapshot(let snapshot) = content,
                      let focused = snapshot.focusedWorkspace else { break }
                frameCache.store(
                    workspace: focused.name,
                    windowIDs: focused.windows.map(\.id),
                    harvest: harvest
                )
                if let layout = frameCache.layout(for: focused) {
                    viewModel.layouts[focused.name] = layout
                }
            case .desktopBackground(let image):
                if let targetDisplayID {
                    cacheDesktopBackground(targetDisplayID, image)
                }
                viewModel.publishDesktopBackground(image)
            case .thumbnail(let id, let image):
                viewModel.thumbnails.update(image, for: id)
                captured += 1
            }
        }
        return captured
    }

    static func consumeLiveFrames(
        _ frames: AsyncStream<LiveThumbnailFrame>,
        viewModel: OverlayViewModel,
        diagnostics: CaptureDiagnostics,
        isCurrent: () -> Bool
    ) async {
        for await frame in frames {
            guard !Task.isCancelled, isCurrent() else { return }
            viewModel.thumbnails.update(frame.image, for: frame.windowID)
            diagnostics.recordUIDelivery(timing: frame.diagnosticsTiming)
        }
    }
}
