import CoreGraphics

struct LiveThumbnailFrame: Sendable {
    let windowID: CGWindowID
    let image: CGImage
    let diagnosticsTiming: DiagnosticsFrameTiming?
}
