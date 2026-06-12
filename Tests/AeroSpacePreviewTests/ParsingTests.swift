import Testing
import CoreGraphics
@testable import AeroSpacePreview

@Suite struct WindowRowParsing {
    @Test func parsesTypicalOutput() throws {
        let fixture = """
        4260\tcom.apple.iCal\tCalendar\t1\tCalendar
        3196\tcom.microsoft.teams2\tMicrosoft Teams\t2\tChat | Team | Microsoft Teams
        3428\tcom.mitchellh.ghostty\tGhostty\t4\t~/Projects/AeroSpacePreview
        """
        let rows = try AeroSpaceParser.parseWindowRows(fixture)
        #expect(rows.count == 3)
        #expect(rows[0].window.id == 4260)
        #expect(rows[0].window.bundleID == "com.apple.iCal")
        #expect(rows[0].window.appName == "Calendar")
        #expect(rows[0].workspace == "1")
        #expect(rows[1].window.title == "Chat | Team | Microsoft Teams")
    }

    @Test func titleMayContainTabs() throws {
        let rows = try AeroSpaceParser.parseWindowRows("7\tcom.x\tX\tws\ttitle\twith\ttabs")
        #expect(rows.count == 1)
        #expect(rows[0].window.title == "title\twith\ttabs")
    }

    @Test func emptyTitleAndBundleID() throws {
        let rows = try AeroSpaceParser.parseWindowRows("7\t\tSomeApp\t1\t")
        #expect(rows[0].window.title == "")
        #expect(rows[0].window.bundleID == "")
    }

    @Test func emptyOutputYieldsNoRows() throws {
        #expect(try AeroSpaceParser.parseWindowRows("").isEmpty)
        #expect(try AeroSpaceParser.parseWindowRows("\n\n").isEmpty)
    }

    @Test func malformedLineThrows() {
        #expect(throws: AeroSpaceError.self) {
            try AeroSpaceParser.parseWindowRows("not-a-number\tcom.x\tX\t1\tt")
        }
        #expect(throws: AeroSpaceError.self) {
            try AeroSpaceParser.parseWindowRows("42\tonly-two-fields")
        }
    }
}

@Suite struct SnapshotBuilding {
    private func row(_ id: CGWindowID, _ workspace: String, app: String = "App") -> AeroSpaceParser.WindowRow {
        .init(window: AeroSpaceWindow(id: id, appName: app, bundleID: "com.\(app)", title: app),
              workspace: workspace)
    }

    @Test func groupsAndSortsNaturally() {
        let snapshot = AeroSpaceParser.buildSnapshot(
            windowRows: [row(1, "10"), row(2, "2"), row(3, "2"), row(4, "mail")],
            focusedWorkspace: "2",
            focusedWindowID: 3
        )
        #expect(snapshot.workspaces.map(\.name) == ["2", "10", "mail"])
        #expect(snapshot.workspaces[0].windows.map(\.id) == [2, 3])
        #expect(snapshot.focusedWorkspace?.name == "2")
        #expect(snapshot.workspaces[0].windows[1].isFocused)
        #expect(!snapshot.workspaces[0].windows[0].isFocused)
    }

    @Test func focusedEmptyWorkspaceIsIncluded() {
        let snapshot = AeroSpaceParser.buildSnapshot(
            windowRows: [row(1, "1")],
            focusedWorkspace: "scratch",
            focusedWindowID: nil
        )
        #expect(snapshot.workspaces.map(\.name) == ["1", "scratch"])
        #expect(snapshot.focusedWorkspace?.windows.isEmpty == true)
    }

    @Test func noFocusedWindowIsLegal() {
        let snapshot = AeroSpaceParser.buildSnapshot(
            windowRows: [row(1, "1")],
            focusedWorkspace: "1",
            focusedWindowID: nil
        )
        #expect(snapshot.allWindows.allSatisfy { !$0.isFocused })
    }
}

@Suite struct NaturalSort {
    @Test func numericAware() {
        #expect(AeroSpaceParser.naturalLess("2", "10"))
        #expect(AeroSpaceParser.naturalLess("ws2", "ws10"))
        #expect(!AeroSpaceParser.naturalLess("10", "2"))
    }

    @Test func alphabetical() {
        #expect(AeroSpaceParser.naturalLess("chat", "mail"))
        #expect(AeroSpaceParser.naturalLess("1", "mail"))
    }
}
