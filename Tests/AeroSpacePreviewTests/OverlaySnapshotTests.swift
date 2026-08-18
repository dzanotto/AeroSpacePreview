import CoreGraphics
import Testing
@testable import AeroSpacePreview

@Suite struct OverlaySnapshotTests {
    @Test func snapshotContentProvidesCaptureAndDiagnosticMetadata() {
        let snapshot = OverlaySnapshot(
            workspaces: [
                workspace(name: "dev", isFocused: true, windowID: 101, appName: "Editor"),
                workspace(name: "mail", isFocused: false, windowID: 202, appName: "Browser"),
            ],
            permissionDenied: false
        )
        let content = OverlayContent.snapshot(snapshot)

        #expect(snapshot.focusedWorkspace?.name == "dev")
        #expect(snapshot.allWindowIDs == [101, 202])
        #expect(content.windowIDsForDiagnostics == [101, 202])
        #expect(content.windowLabelsForDiagnostics == [101: "Editor", 202: "Browser"])
    }

    @Test func errorContentHasNoCaptureOrDiagnosticMetadata() {
        let content = OverlayContent.error("unavailable")

        #expect(content.windowIDsForDiagnostics.isEmpty)
        #expect(content.windowLabelsForDiagnostics.isEmpty)
    }

    private func workspace(
        name: String,
        isFocused: Bool,
        windowID: CGWindowID,
        appName: String
    ) -> AeroSpaceWorkspace {
        AeroSpaceWorkspace(
            name: name,
            isFocused: isFocused,
            windows: [AeroSpaceWindow(
                id: windowID,
                appName: appName,
                bundleID: "com.example.\(appName.lowercased())",
                title: name
            )]
        )
    }
}
