import Testing
@testable import AeroSpacePreview

@Suite struct GridColumns {
    @Test func capsAtFour() {
        #expect(OverlayKeyLogic.columns(for: 1) == 1)
        #expect(OverlayKeyLogic.columns(for: 3) == 3)
        #expect(OverlayKeyLogic.columns(for: 9) == 4)
        #expect(OverlayKeyLogic.columns(for: 0) == 1)
    }
}

@Suite struct ArrowMovement {
    // 5 workspaces, 4 columns: [0 1 2 3] / [4]
    @Test func leftRightWrap() {
        #expect(OverlayKeyLogic.move(index: 0, count: 5, columns: 4, arrow: .left) == 4)
        #expect(OverlayKeyLogic.move(index: 4, count: 5, columns: 4, arrow: .right) == 0)
        #expect(OverlayKeyLogic.move(index: 1, count: 5, columns: 4, arrow: .right) == 2)
    }

    @Test func upDownClampAtEdges() {
        #expect(OverlayKeyLogic.move(index: 0, count: 5, columns: 4, arrow: .down) == 4)
        #expect(OverlayKeyLogic.move(index: 1, count: 5, columns: 4, arrow: .down) == 1) // no row below
        #expect(OverlayKeyLogic.move(index: 4, count: 5, columns: 4, arrow: .up) == 0)
        #expect(OverlayKeyLogic.move(index: 2, count: 5, columns: 4, arrow: .up) == 2) // already top row
    }

    @Test func singleWorkspaceIsStable() {
        for arrow in [OverlayKeyLogic.Arrow.left, .right, .up, .down] {
            #expect(OverlayKeyLogic.move(index: 0, count: 1, columns: 1, arrow: arrow) == 0)
        }
    }
}

@Suite struct PrefixMatching {
    let names = ["1", "10", "2", "mail", "misc"]

    @Test func uniqueExactNameActivates() {
        #expect(OverlayKeyLogic.prefixMatch("2", names: names) == .activate(2))
        #expect(OverlayKeyLogic.prefixMatch("mail", names: names) == .activate(3))
    }

    @Test func ambiguousPrefixSelectsFirst() {
        // "1" prefixes both "1" and "10" — select, don't switch.
        #expect(OverlayKeyLogic.prefixMatch("1", names: names) == .select(0))
        #expect(OverlayKeyLogic.prefixMatch("m", names: names) == .select(3))
    }

    @Test func caseInsensitive() {
        #expect(OverlayKeyLogic.prefixMatch("MAIL", names: names) == .activate(3))
    }

    @Test func noMatch() {
        #expect(OverlayKeyLogic.prefixMatch("z", names: names) == .noMatch)
        #expect(OverlayKeyLogic.prefixMatch("", names: names) == .noMatch)
    }
}
