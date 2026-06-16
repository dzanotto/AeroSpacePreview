import AppKit
import CoreGraphics
import SwiftUI

/// Per-summon view state: which workspace tile is selected and the
/// type-to-select buffer. Key events arrive from the panel via `handle`.
/// Thumbnails arrive after presentation — the overlay shows placeholders
/// until the capture pass finishes (~30 ms per window, serialized by SCK).
@MainActor
final class OverlayViewModel: ObservableObject {
    @Published private(set) var selectedWorkspace: String?
    @Published private(set) var typedPrefix = ""
    @Published var thumbnails: [CGWindowID: CGImage] = [:]
    /// Workspace name → validated miniature layout. Tiles without an entry
    /// render the uniform grid. Seeded from the frame cache at presentation;
    /// the focused workspace's entry refreshes when its summon-time frames
    /// arrive with the capture stream.
    @Published var layouts: [String: WorkspaceLayout] = [:]

    let content: OverlayContent
    let actions: OverlayActions

    private let workspaceNames: [String]
    private let columns: Int
    private var typedResetTask: Task<Void, Never>?

    init(content: OverlayContent, actions: OverlayActions) {
        self.content = content
        self.actions = actions
        if case .snapshot(let snapshot) = content {
            workspaceNames = snapshot.workspaces.map(\.name)
            columns = OverlayKeyLogic.columns(for: snapshot.workspaces.count)
            selectedWorkspace = snapshot.workspaces.first(where: \.isFocused)?.name
                ?? snapshot.workspaces.first?.name
        } else {
            workspaceNames = []
            columns = 1
        }
    }

    var gridColumns: Int { columns }

    /// Returns true if the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard !workspaceNames.isEmpty else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }

        switch event.keyCode {
        case 123: move(.left); return true
        case 124: move(.right); return true
        case 126: move(.up); return true
        case 125: move(.down); return true
        case 36, 76: // Return, keypad Enter
            if let selectedWorkspace { actions.selectWorkspace(selectedWorkspace) }
            return true
        case 51: // Backspace
            setTypedPrefix(String(typedPrefix.dropLast()))
            return true
        case 53: // Esc falls through to cancelOperation
            return false
        default:
            guard let chars = event.charactersIgnoringModifiers,
                  !chars.isEmpty,
                  chars.allSatisfy({ !$0.isWhitespace && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol) })
            else { return false }
            setTypedPrefix(typedPrefix + chars.lowercased())
            return true
        }
    }

    private func move(_ arrow: OverlayKeyLogic.Arrow) {
        clearTypedPrefix()
        let current = selectedWorkspace.flatMap(workspaceNames.firstIndex(of:)) ?? 0
        let next = OverlayKeyLogic.move(
            index: current, count: workspaceNames.count, columns: columns, arrow: arrow
        )
        selectedWorkspace = workspaceNames[next]
    }

    private func setTypedPrefix(_ prefix: String) {
        typedPrefix = prefix
        scheduleTypedReset()
        switch OverlayKeyLogic.prefixMatch(prefix, names: workspaceNames) {
        case .activate(let index):
            actions.selectWorkspace(workspaceNames[index])
        case .select(let index):
            selectedWorkspace = workspaceNames[index]
        case .noMatch:
            if !prefix.isEmpty { typedPrefix = "" } // dead-end input resets the buffer
        }
    }

    private func clearTypedPrefix() {
        typedResetTask?.cancel()
        typedPrefix = ""
    }

    private func scheduleTypedReset() {
        typedResetTask?.cancel()
        typedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.typedPrefix = ""
        }
    }
}
