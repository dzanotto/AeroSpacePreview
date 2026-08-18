import AppKit
import ServiceManagement

/// Menu bar presence for the agent app. Because the app is `LSUIElement` it has
/// no Dock icon and the overlay is its only window, so without this there is no
/// way to see it's running or quit it short of `pkill`. The status item's menu
/// can summon the overlay, configure workspace visibility, toggle diagnostics
/// or launch-at-login, show an about box, and quit.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let onToggleOverlay: () -> Void
    private let isShowingEmptyWorkspaces: () -> Bool
    private let onToggleShowEmptyWorkspaces: () -> Void
    private let isDiagnosticsEnabled: () -> Bool
    private let onToggleDiagnostics: () -> Void

    init(
        onToggleOverlay: @escaping () -> Void,
        isShowingEmptyWorkspaces: @escaping () -> Bool,
        onToggleShowEmptyWorkspaces: @escaping () -> Void,
        isDiagnosticsEnabled: @escaping () -> Bool,
        onToggleDiagnostics: @escaping () -> Void
    ) {
        self.onToggleOverlay = onToggleOverlay
        self.isShowingEmptyWorkspaces = isShowingEmptyWorkspaces
        self.onToggleShowEmptyWorkspaces = onToggleShowEmptyWorkspaces
        self.isDiagnosticsEnabled = isDiagnosticsEnabled
        self.onToggleDiagnostics = onToggleDiagnostics
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "square.grid.2x2",
                accessibilityDescription: "AeroSpacePreview"
            )
            image?.isTemplate = true // adopts the menu bar's light/dark appearance
            button.image = image
        }
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self // refreshes the login-item checkmark on open

        let show = NSMenuItem(
            title: "Show Workspace Preview",
            action: #selector(showOverlay),
            keyEquivalent: "s"
        )
        show.keyEquivalentModifierMask = [.command, .control, .option, .shift] // Hyper, for display
        show.target = self
        menu.addItem(show)

        let emptyWorkspaces = NSMenuItem(
            title: "Show Empty Workspaces",
            action: #selector(toggleShowEmptyWorkspaces),
            keyEquivalent: ""
        )
        emptyWorkspaces.target = self
        menu.addItem(emptyWorkspaces)

        let diagnostics = NSMenuItem(
            title: "Show Diagnostics",
            action: #selector(toggleDiagnostics),
            keyEquivalent: ""
        )
        diagnostics.target = self
        menu.addItem(diagnostics)

        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: "About AeroSpacePreview",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(
            title: "Quit AeroSpacePreview",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func showOverlay() {
        onToggleOverlay()
    }

    @objc private func toggleDiagnostics() {
        onToggleDiagnostics()
    }

    @objc private func toggleShowEmptyWorkspaces() {
        onToggleShowEmptyWorkspaces()
    }

    /// Registers/unregisters the app as a login item via `SMAppService` (no
    /// helper bundle needed — `.mainApp` launches this very app at login).
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("AeroSpacePreview: launch-at-login toggle failed: \(error)")
        }
    }

    @objc private func showAbout() {
        // Accessory apps aren't active, so the panel would open behind other
        // windows without this.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil) // reads version from the bundle Info.plist
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let emptyWorkspaces = menu.items.first(where: {
            $0.action == #selector(toggleShowEmptyWorkspaces)
        }) {
            emptyWorkspaces.state = isShowingEmptyWorkspaces() ? .on : .off
        }
        if let diagnostics = menu.items.first(where: { $0.action == #selector(toggleDiagnostics) }) {
            diagnostics.state = isDiagnosticsEnabled() ? .on : .off
        }
        if let login = menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) }) {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }
}
