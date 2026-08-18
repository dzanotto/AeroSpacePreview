import Foundation

@MainActor
final class AppPreferences {
    private static let showEmptyWorkspacesKey = "showEmptyWorkspaces"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var showEmptyWorkspaces: Bool {
        get { defaults.bool(forKey: Self.showEmptyWorkspacesKey) }
        set { defaults.set(newValue, forKey: Self.showEmptyWorkspacesKey) }
    }
}
