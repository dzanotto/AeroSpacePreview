import AppKit
import CoreGraphics

/// Fallback card for windows that couldn't be captured: the app's icon
/// centered on a neutral rounded card.
enum PlaceholderRenderer {
    static func appIcon(bundleID: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    /// Renders the full card as a CGImage (used by `--dump-images`; the
    /// overlay UI composes the same look natively in SwiftUI).
    static func render(bundleID: String, size: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: max(1, Int(size.width)),
            height: max(1, Int(size.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()

        if let icon = appIcon(bundleID: bundleID),
           let iconCG = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let iconSide = min(size.width, size.height) * 0.5
            let iconRect = CGRect(
                x: (size.width - iconSide) / 2,
                y: (size.height - iconSide) / 2,
                width: iconSide,
                height: iconSide
            )
            context.draw(iconCG, in: iconRect)
        }
        return context.makeImage()
    }
}
