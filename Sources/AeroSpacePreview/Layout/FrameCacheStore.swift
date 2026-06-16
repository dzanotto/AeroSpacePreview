import CoreGraphics
import Foundation

/// A workspace's window layout in display-relative unit coordinates
/// (top-left origin, matching both ScreenCaptureKit frames and SwiftUI).
struct WorkspaceLayout: Equatable, Sendable {
    /// Per-window frame normalized to the display: x/y/width/height as
    /// fractions of the display bounds. Windows hanging off the display edge
    /// may exceed the unit square; the rendering view clips.
    let frames: [CGWindowID: CGRect]
    /// Width / height of the display the frames were normalized against, so
    /// the miniature can letterbox at the real screen proportions.
    let displayAspect: CGFloat
}

/// Pure geometry for building, validating, and fitting cached layouts.
enum LayoutMath {
    /// Picks the display the windows sit on: the one overlapping the most
    /// total window area. Single-monitor in practice (spec §6 defers
    /// multi-monitor), but cheap to get right now.
    static func pickDisplay(for frames: some Collection<CGRect>, displays: [CGRect]) -> CGRect? {
        displays.max { overlapArea(frames, $0) < overlapArea(frames, $1) }
    }

    private static func overlapArea(_ frames: some Collection<CGRect>, _ display: CGRect) -> CGFloat {
        frames.reduce(0) { area, frame in
            let overlap = frame.intersection(display)
            return area + (overlap.isNull ? 0 : overlap.width * overlap.height)
        }
    }

    /// Normalizes window frames (global top-left-origin coordinates, as
    /// reported by SCWindow/SCDisplay) against the display they sit on.
    static func normalize(frames: [CGWindowID: CGRect], displays: [CGRect]) -> WorkspaceLayout? {
        guard !frames.isEmpty,
              let display = pickDisplay(for: frames.values, displays: displays),
              display.width > 0, display.height > 0
        else { return nil }
        let unit = frames.mapValues { frame in
            CGRect(
                x: (frame.minX - display.minX) / display.width,
                y: (frame.minY - display.minY) / display.height,
                width: frame.width / display.width,
                height: frame.height / display.height
            )
        }
        return WorkspaceLayout(frames: unit, displayAspect: display.width / display.height)
    }

    /// A cached layout is usable only if it covers exactly the workspace's
    /// current window set — any mismatch (window opened/closed while the
    /// workspace was hidden) falls back to the uniform grid. No partial
    /// hybrids: simple and predictable.
    static func isValid(_ layout: WorkspaceLayout, for windowIDs: some Collection<CGWindowID>) -> Bool {
        !layout.frames.isEmpty && Set(layout.frames.keys) == Set(windowIDs)
    }

    /// Largest rect of the given aspect (width / height) centered in `size` —
    /// how a display miniature sits inside a tile of a different shape.
    static func letterbox(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        let height = min(size.height, size.width / aspect)
        let width = height * aspect
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }
}

/// Workspace name → last-seen window layout. Frames are only trustworthy for
/// the *visible* workspace (AeroSpace stacks hidden ones off-viewport, per
/// M0), so entries are harvested at moments the workspace is known to be on
/// screen: every summon, and shortly after the overlay switches workspace —
/// normal use populates the cache by itself. In-memory for the app's
/// lifetime; persistence would rarely pay off since window IDs die with
/// their owning apps.
@MainActor
final class FrameCacheStore {
    private struct Entry {
        let layout: WorkspaceLayout
        let harvestedAt: Date
    }

    private var entries: [String: Entry] = [:]

    /// Stores a harvest, keeping only the given workspace's windows (the
    /// shareable-content lookup sees every window on the system).
    func store(workspace: String, windowIDs: some Collection<CGWindowID>, harvest: WindowFrameHarvest) {
        let relevant = harvest.frames.filter { windowIDs.contains($0.key) }
        guard let layout = LayoutMath.normalize(frames: relevant, displays: harvest.displays) else { return }
        entries[workspace] = Entry(layout: layout, harvestedAt: Date())
    }

    /// The cached layout for a workspace, or nil (→ uniform grid) if nothing
    /// was harvested or the window set changed since harvest.
    func layout(for workspace: AeroSpaceWorkspace) -> WorkspaceLayout? {
        guard let entry = entries[workspace.name],
              LayoutMath.isValid(entry.layout, for: workspace.windows.map(\.id))
        else { return nil }
        return entry.layout
    }
}
