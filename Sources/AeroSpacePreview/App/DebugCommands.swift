import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `--dump-images <dir>`: capture a thumbnail (or placeholder) for every
/// window AeroSpace knows about and write PNGs. M3 exit-criteria harness.
enum DumpImagesCommand {
    static func run(outputDir: URL) async -> Int32 {
        do {
            let snapshot = try AeroSpaceClient.discover().fetchSnapshot()
            let windows = snapshot.allWindows
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let service = CaptureService()
            await service.warmUp()

            let clock = ContinuousClock()
            let start = clock.now
            let images = await service.thumbnails(for: windows.map(\.id), maxPixel: 640)
            let elapsed = start.duration(to: clock.now)

            for window in windows {
                let safeApp = window.appName.replacingOccurrences(of: "/", with: "-")
                if let image = images[window.id] {
                    let url = outputDir.appendingPathComponent("win-\(window.id)-\(safeApp).png")
                    try writePNG(image, to: url)
                    print("OK          \(window.id) \(window.appName) \(image.width)x\(image.height)")
                } else if let placeholder = PlaceholderRenderer.render(
                    bundleID: window.bundleID, size: CGSize(width: 320, height: 200)
                ) {
                    let url = outputDir.appendingPathComponent("placeholder-\(window.id)-\(safeApp).png")
                    try writePNG(placeholder, to: url)
                    print("PLACEHOLDER \(window.id) \(window.appName)")
                } else {
                    print("FAIL        \(window.id) \(window.appName) — no capture, no placeholder")
                }
            }
            print("captured \(images.count)/\(windows.count) windows in \(elapsed) (post-warm-up)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
