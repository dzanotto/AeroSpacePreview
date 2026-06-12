// R2 spike: capture windows (incl. ones on hidden AeroSpace workspaces) via
// SCScreenshotManager and write PNGs. Usage: r2_capture.swift <out-dir> <window-id>...
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
import AppKit

// SCContentFilter requires an initialized window-server connection (CGS);
// touching NSApplication.shared establishes it. The real app won't need this.
_ = NSApplication.shared

let args = CommandLine.arguments.dropFirst()
guard args.count >= 2, let outDir = args.first.map(URL.init(fileURLWithPath:)) else {
    print("usage: r2_capture.swift <out-dir> <window-id>...")
    exit(1)
}
let ids: [CGWindowID] = args.dropFirst().compactMap { UInt32($0) }
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        print("SCShareableContent: \(content.windows.count) windows visible to SCK")
        for id in ids {
            guard let scWindow = content.windows.first(where: { $0.windowID == id }) else {
                print("MISS  \(id) — not in SCShareableContent")
                continue
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(scWindow.frame.width / 2)
            config.height = Int(scWindow.frame.height / 2)
            config.showsCursor = false
            let start = ContinuousClock.now
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let elapsed = start.duration(to: .now)
                // crude blank check: sample some pixels for variance
                let blank = isLikelyBlank(image)
                let url = outDir.appendingPathComponent("win-\(id)-\(scWindow.owningApplication?.applicationName ?? "unknown").png")
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                }
                print("OK    \(id) app=\(scWindow.owningApplication?.applicationName ?? "?") size=\(image.width)x\(image.height) blank=\(blank) elapsed=\(elapsed) -> \(url.lastPathComponent)")
            } catch {
                print("FAIL  \(id) — \(error)")
            }
        }
    } catch {
        print("SCShareableContent error: \(error)")
    }
    sema.signal()
}

func isLikelyBlank(_ image: CGImage) -> Bool {
    guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return true }
    let len = CFDataGetLength(data)
    guard len > 0 else { return true }
    var seen = Set<UInt8>()
    for i in stride(from: 0, to: len, by: max(1, len / 2048)) { seen.insert(ptr[i]) }
    return seen.count <= 2
}

sema.wait()
