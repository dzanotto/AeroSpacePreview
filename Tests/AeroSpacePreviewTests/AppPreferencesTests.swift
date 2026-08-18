import Foundation
import Testing
@testable import AeroSpacePreview

@Suite @MainActor struct AppPreferencesTests {
    @Test func emptyWorkspacesAreHiddenByDefaultAndTheChoicePersists() throws {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        #expect(!preferences.showEmptyWorkspaces)

        preferences.showEmptyWorkspaces = true

        #expect(AppPreferences(defaults: defaults).showEmptyWorkspaces)
    }
}
