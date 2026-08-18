import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private lazy var overlay = OverlayController(
        diagnosticsEnabled: CommandLine.arguments.contains("--debug-hud"),
        showEmptyWorkspaces: preferences.showEmptyWorkspaces
    )
    private var hotKey: HotKeyManager?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(
            onToggleOverlay: { [weak self] in self?.overlay.toggle() },
            isShowingEmptyWorkspaces: { [weak self] in
                self?.overlay.isShowingEmptyWorkspaces ?? false
            },
            onToggleShowEmptyWorkspaces: { [weak self] in
                guard let self else { return }
                self.overlay.toggleShowEmptyWorkspaces()
                self.preferences.showEmptyWorkspaces = self.overlay.isShowingEmptyWorkspaces
            },
            isDiagnosticsEnabled: { [weak self] in self?.overlay.isDiagnosticsEnabled ?? false },
            onToggleDiagnostics: { [weak self] in self?.overlay.toggleDiagnostics() }
        )

        hotKey = HotKeyManager(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey)
        ) { [weak self] in
            self?.overlay.toggle()
        }

        if hotKey == nil {
            NSLog("AeroSpacePreview: failed to register Hyper+S — is another app using it?")
        } else {
            NSLog("AeroSpacePreview: ready — Hyper+S (⌘⌃⌥⇧S) toggles the overlay")
        }

        // Pays the one-time SCK session cost (~370 ms) now instead of on the
        // first summon; also triggers the permission prompt on first run.
        Task.detached {
            await OneShotCaptureService().warmUp()
        }

        if CommandLine.arguments.contains("--show-on-launch") {
            overlay.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.shutdown()
    }
}
