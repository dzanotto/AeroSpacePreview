import AppKit
import CoreGraphics
import Testing
@testable import AeroSpacePreview

@MainActor
@Suite struct OverlayViewModelTests {
    @Test func initialSelectionPrefersFocusAndErrorContentDoesNotConsumeKeys() {
        let recorder = OverlayActionRecorder()
        let viewModel = makeViewModel(
            names: ["1", "2", "3"],
            focusedName: "2",
            recorder: recorder
        )

        #expect(viewModel.selectedWorkspace == "2")
        #expect(viewModel.gridColumns == 3)

        let errorViewModel = OverlayViewModel(
            content: .error("unavailable"),
            actions: recorder.actions
        )
        #expect(errorViewModel.selectedWorkspace == nil)
        #expect(errorViewModel.gridColumns == 1)
        #expect(!errorViewModel.handle(keyEvent(keyCode: 0, characters: "a")))
        #expect(!errorViewModel.handle(keyEvent(keyCode: 36)))
        #expect(recorder.selectedWorkspaces.isEmpty)
    }

    @Test func arrowNavigationClearsTypingAndReturnActivatesTheSelection() {
        let recorder = OverlayActionRecorder()
        let viewModel = makeViewModel(
            names: ["1", "2", "3", "mail", "misc"],
            focusedName: "1",
            recorder: recorder
        )

        #expect(viewModel.handle(keyEvent(keyCode: 0, characters: "m")))
        #expect(viewModel.typedPrefix == "m")
        #expect(viewModel.selectedWorkspace == "mail")

        #expect(viewModel.handle(keyEvent(keyCode: 124)))
        #expect(viewModel.selectedWorkspace == "misc")
        #expect(viewModel.typedPrefix.isEmpty)

        #expect(viewModel.handle(keyEvent(keyCode: 36)))
        #expect(recorder.selectedWorkspaces == ["misc"])
    }

    @Test func typingConnectsAmbiguousSelectionExactActivationBackspaceAndDeadEnds() {
        let recorder = OverlayActionRecorder()
        let viewModel = makeViewModel(
            names: ["1", "10", "mail", "misc"],
            focusedName: "misc",
            recorder: recorder
        )

        #expect(viewModel.handle(keyEvent(keyCode: 0, characters: "m")))
        #expect(viewModel.selectedWorkspace == "mail")
        #expect(viewModel.typedPrefix == "m")
        #expect(recorder.selectedWorkspaces.isEmpty)

        #expect(viewModel.handle(keyEvent(keyCode: 0, characters: "a")))
        #expect(viewModel.typedPrefix == "ma")
        #expect(viewModel.handle(keyEvent(keyCode: 51)))
        #expect(viewModel.typedPrefix == "m")

        #expect(viewModel.handle(keyEvent(keyCode: 0, characters: "z")))
        #expect(viewModel.typedPrefix.isEmpty)

        #expect(viewModel.handle(keyEvent(keyCode: 0, characters: "1")))
        #expect(viewModel.selectedWorkspace == "1")
        #expect(recorder.selectedWorkspaces.isEmpty)
        #expect(viewModel.handle(keyEvent(keyCode: 0, characters: "0")))
        #expect(recorder.selectedWorkspaces == ["10"])
    }

    @Test func modifiedWhitespaceAndEscapeEventsPassThroughWithoutChangingState() {
        let recorder = OverlayActionRecorder()
        let viewModel = makeViewModel(
            names: ["dev", "mail"],
            focusedName: "dev",
            recorder: recorder
        )

        #expect(!viewModel.handle(keyEvent(
            keyCode: 124,
            modifierFlags: .command
        )))
        #expect(!viewModel.handle(keyEvent(keyCode: 0, characters: " ")))
        #expect(!viewModel.handle(keyEvent(keyCode: 53)))
        #expect(viewModel.selectedWorkspace == "dev")
        #expect(viewModel.typedPrefix.isEmpty)
        #expect(recorder.selectedWorkspaces.isEmpty)
    }

    @Test func typedPrefixExpiresAfterTheConfiguredInactivityPeriod() async throws {
        let recorder = OverlayActionRecorder()
        let viewModel = makeViewModel(
            names: ["dev", "mail"],
            focusedName: "dev",
            recorder: recorder,
            typedPrefixResetDelay: .milliseconds(20)
        )

        #expect(viewModel.handle(keyEvent(keyCode: 0, characters: "m")))
        #expect(viewModel.typedPrefix == "m")

        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.typedPrefix.isEmpty)
    }

    private func makeViewModel(
        names: [String],
        focusedName: String?,
        recorder: OverlayActionRecorder,
        typedPrefixResetDelay: Duration = .seconds(1.5)
    ) -> OverlayViewModel {
        let workspaces = names.map { name in
            AeroSpaceWorkspace(
                name: name,
                isFocused: name == focusedName,
                windows: [AeroSpaceWindow(
                    id: CGWindowID(name.hashValue.magnitude % 10_000 + 1),
                    appName: "App",
                    bundleID: "com.example.app",
                    title: name
                )]
            )
        }
        return OverlayViewModel(
            content: .snapshot(OverlaySnapshot(
                workspaces: workspaces,
                permissionDenied: false
            )),
            actions: recorder.actions,
            typedPrefixResetDelay: typedPrefixResetDelay
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String = "",
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

@MainActor
private final class OverlayActionRecorder {
    private(set) var dismissCount = 0
    private(set) var selectedWorkspaces: [String] = []
    private(set) var focusedWindowIDs: [CGWindowID] = []

    var actions: OverlayActions {
        OverlayActions(
            dismiss: { [weak self] in self?.dismissCount += 1 },
            selectWorkspace: { [weak self] in self?.selectedWorkspaces.append($0) },
            focusWindow: { [weak self] in self?.focusedWindowIDs.append($0) }
        )
    }
}
