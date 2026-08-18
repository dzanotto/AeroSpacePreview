import CoreGraphics

/// OS-independent scheduling for the one-shot capture pass. ScreenCaptureKit
/// supplies the jobs; this type owns event ordering, bounded execution, and
/// omission of failed captures.
struct OneShotCaptureBatch: Sendable {
    struct Job: Sendable {
        enum Result: Sendable {
            case desktopBackground(CGImage?)
            case thumbnail(CGWindowID, CGImage?)
        }

        let run: @Sendable () async -> Result

        init(_ run: @escaping @Sendable () async -> Result) {
            self.run = run
        }
    }

    let frames: WindowFrameHarvest
    let jobs: [Job]
    let maximumConcurrentTasks: Int

    func run(_ receive: @Sendable (CaptureEvent) -> Void) async {
        // Geometry is useful without pixels and must always be published first.
        receive(.frames(frames))

        let batch = BoundedAsyncBatch(
            elements: jobs,
            maximumConcurrentTasks: maximumConcurrentTasks,
            operation: { await $0.run() }
        )
        await batch.run { result in
            switch result {
            case .desktopBackground(let image):
                if let image { receive(.desktopBackground(image)) }
            case .thumbnail(let id, let image):
                if let image { receive(.thumbnail(id, image)) }
            }
        }
    }
}
