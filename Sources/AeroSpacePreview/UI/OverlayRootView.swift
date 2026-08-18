import SwiftUI

struct OverlayRootView: View {
    @ObservedObject var viewModel: OverlayViewModel

    private var actions: OverlayActions { viewModel.actions }

    var body: some View {
        ZStack {
            VisualEffectBackdrop()
            desktopBackground
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { actions.dismiss() }

            switch viewModel.content {
            case .snapshot(let snapshot):
                VStack(spacing: 16) {
                    if snapshot.permissionDenied {
                        permissionHint
                    }
                    workspaceGrid(snapshot)
                    typedPrefixPill
                }
                .padding(48)
            case .error(let message):
                errorCard(message)
            }
        }
        .animation(.easeOut(duration: 0.12), value: viewModel.desktopBackground == nil)
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            if let snapshot = viewModel.diagnosticsSnapshot {
                DiagnosticsHUDView(snapshot: snapshot)
                    .padding(20)
            }
        }
    }

    @ViewBuilder
    private var desktopBackground: some View {
        if let image = viewModel.desktopBackground {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1.02)
                .blur(radius: 10)
                .clipped()
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func workspaceGrid(_ snapshot: OverlaySnapshot) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(maximum: 440), spacing: 24),
                count: viewModel.gridColumns
            ),
            spacing: 24
        ) {
            ForEach(snapshot.workspaces, id: \.name) { workspace in
                WorkspaceTileView(
                    workspace: workspace,
                    thumbnails: viewModel.thumbnails,
                    layout: viewModel.layouts[workspace.name],
                    isSelected: workspace.name == viewModel.selectedWorkspace,
                    actions: actions
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var typedPrefixPill: some View {
        if !viewModel.typedPrefix.isEmpty {
            Text(viewModel.typedPrefix)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.15)))
        }
    }

    private var permissionHint: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Screen Recording permission is needed for window thumbnails.")
                .foregroundStyle(.white.opacity(0.9))
            Button("Open System Settings") {
                ScreenRecordingPermission.openSystemSettings()
                actions.dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1)))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group.bubble.left")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.5))
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Text("Press Esc to dismiss")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(32)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.08)))
    }
}
