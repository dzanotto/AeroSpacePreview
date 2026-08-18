import CoreGraphics
import SwiftUI

struct WorkspaceTileView: View {
    let workspace: AeroSpaceWorkspace
    let thumbnails: ThumbnailStore
    /// Validated miniature layout, or nil → uniform grid fallback.
    let layout: WorkspaceLayout?
    let isSelected: Bool
    let actions: OverlayActions

    // Selection (keyboard cursor, white) is visually distinct from the
    // focused workspace (accent color).
    private var borderColor: Color {
        if isSelected { return .white.opacity(0.9) }
        if workspace.isFocused { return .accentColor }
        return .white.opacity(0.15)
    }

    private var borderWidth: CGFloat {
        isSelected ? 3 : workspace.isFocused ? 2.5 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workspace.name)
                .font(.system(size: 15, weight: workspace.isFocused || isSelected ? .bold : .medium))
                .foregroundStyle(workspace.isFocused ? Color.accentColor : .white.opacity(isSelected ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)

            windowArea
                .aspectRatio(16 / 10, contentMode: .fit)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(isSelected ? 0.13 : workspace.isFocused ? 0.10 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { actions.selectWorkspace(workspace.name) }
        }
    }

    @ViewBuilder
    private var windowArea: some View {
        if workspace.windows.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let layout {
            WorkspaceLayoutView(
                workspace: workspace,
                layout: layout,
                thumbnails: thumbnails,
                actions: actions
            )
        } else {
            let columns = Int(Double(workspace.windows.count).squareRoot().rounded(.up))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                spacing: 8
            ) {
                ForEach(workspace.windows, id: \.id) { window in
                    WindowThumbnailView(
                        window: window,
                        thumbnail: thumbnails.slot(for: window.id)
                    )
                    .onTapGesture { actions.focusWindow(window.id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Miniature of the workspace's real tiled layout: each thumbnail placed at
/// its cached display-relative frame, letterboxed to the display's aspect
/// inside the (16:10) tile area. Only rendered with a validated layout, so
/// every window has a frame.
struct WorkspaceLayoutView: View {
    let workspace: AeroSpaceWorkspace
    let layout: WorkspaceLayout
    let thumbnails: ThumbnailStore
    let actions: OverlayActions

    var body: some View {
        GeometryReader { geo in
            let box = LayoutMath.letterbox(aspect: layout.displayAspect, in: geo.size)
            ForEach(workspace.windows, id: \.id) { window in
                if let unit = layout.frames[window.id] {
                    WindowThumbnailView(
                        window: window,
                        thumbnail: thumbnails.slot(for: window.id),
                        fillsCell: true
                    )
                    .frame(width: unit.width * box.width, height: unit.height * box.height)
                    .position(
                        x: box.minX + unit.midX * box.width,
                        y: box.minY + unit.midY * box.height
                    )
                    .onTapGesture { actions.focusWindow(window.id) }
                }
            }
        }
        .clipped()
    }
}

struct WindowThumbnailView: View {
    let window: AeroSpaceWindow
    @ObservedObject var thumbnail: ThumbnailStore.Slot
    /// In the layout miniature the cell already has the window's shape — the
    /// content stretches to fill it. In the uniform grid the content sizes
    /// itself (fit, 16:10 placeholder).
    var fillsCell = false

    var body: some View {
        Group {
            if let image = thumbnail.image {
                let img = Image(decorative: image, scale: 1).resizable()
                if fillsCell { img } else { img.scaledToFit() }
            } else {
                placeholderCard
            }
        }
        .animation(.easeOut(duration: 0.12), value: thumbnail.image == nil)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    window.isFocused ? Color.accentColor : .white.opacity(0.25),
                    lineWidth: window.isFocused ? 2 : 1
                )
        )
        .help(window.title)
    }

    private var placeholderCard: some View {
        ZStack {
            Color(white: 0.22)
            VStack(spacing: 4) {
                if let icon = PlaceholderRenderer.appIcon(bundleID: window.bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 48, maxHeight: 48)
                }
                Text(window.appName)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(6)
        }
        .aspectRatio(fillsCell ? nil : 16 / 10, contentMode: .fit)
    }
}
