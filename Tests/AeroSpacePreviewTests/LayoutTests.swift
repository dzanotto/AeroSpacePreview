import Testing
import CoreGraphics
@testable import AeroSpacePreview

@Suite struct LayoutMathTests {
    let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    @Test func normalizationRoundTrips() throws {
        let frames: [CGWindowID: CGRect] = [
            1: CGRect(x: 10, y: 40, width: 780, height: 950),
            2: CGRect(x: 800, y: 40, width: 790, height: 470),
        ]
        let layout = try #require(LayoutMath.normalize(frames: frames, displays: [display]))
        #expect(layout.displayAspect == 1.6)
        for (id, original) in frames {
            let unit = try #require(layout.frames[id])
            let restored = CGRect(
                x: unit.minX * display.width + display.minX,
                y: unit.minY * display.height + display.minY,
                width: unit.width * display.width,
                height: unit.height * display.height
            )
            #expect(abs(restored.minX - original.minX) < 0.001)
            #expect(abs(restored.minY - original.minY) < 0.001)
            #expect(abs(restored.width - original.width) < 0.001)
            #expect(abs(restored.height - original.height) < 0.001)
        }
    }

    @Test func normalizesAgainstTheDisplayTheWindowsSitOn() throws {
        let second = CGRect(x: 1600, y: 0, width: 2000, height: 1000)
        let frames: [CGWindowID: CGRect] = [7: CGRect(x: 1700, y: 100, width: 1000, height: 500)]
        let layout = try #require(LayoutMath.normalize(frames: frames, displays: [display, second]))
        let unit = try #require(layout.frames[7])
        #expect(abs(unit.minX - 0.05) < 0.001) // (1700-1600)/2000, not 1700/1600
        #expect(layout.displayAspect == 2.0)
    }

    @Test func emptyFramesOrNoDisplaysYieldNoLayout() {
        #expect(LayoutMath.normalize(frames: [:], displays: [display]) == nil)
        #expect(LayoutMath.normalize(frames: [1: CGRect(x: 0, y: 0, width: 10, height: 10)], displays: []) == nil)
    }

    @Test func validationRequiresExactWindowSetMatch() {
        let layout = WorkspaceLayout(
            frames: [1: CGRect(x: 0, y: 0, width: 0.5, height: 1), 2: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)],
            displayAspect: 1.6
        )
        #expect(LayoutMath.isValid(layout, for: [1, 2]))
        #expect(LayoutMath.isValid(layout, for: [2, 1])) // order-insensitive
        #expect(!LayoutMath.isValid(layout, for: [1])) // window closed while hidden
        #expect(!LayoutMath.isValid(layout, for: [1, 2, 3])) // window opened while hidden
        #expect(!LayoutMath.isValid(WorkspaceLayout(frames: [:], displayAspect: 1.6), for: []))
    }

    @Test func letterboxFitsAndCenters() {
        // Wide display in a squarer box: full width, vertically centered.
        let wide = LayoutMath.letterbox(aspect: 2.0, in: CGSize(width: 400, height: 250))
        #expect(wide == CGRect(x: 0, y: 25, width: 400, height: 200))
        // Tall content in a wide box: full height, horizontally centered.
        let tall = LayoutMath.letterbox(aspect: 0.5, in: CGSize(width: 400, height: 200))
        #expect(tall == CGRect(x: 150, y: 0, width: 100, height: 200))
        #expect(LayoutMath.letterbox(aspect: 0, in: CGSize(width: 400, height: 200)) == .zero)
    }
}

@MainActor
@Suite struct FrameCacheStoreTests {
    private func workspace(_ name: String, windowIDs: [CGWindowID]) -> AeroSpaceWorkspace {
        AeroSpaceWorkspace(
            name: name,
            isFocused: false,
            windows: windowIDs.map {
                AeroSpaceWindow(id: $0, appName: "App", bundleID: "com.x", title: "t")
            }
        )
    }

    @Test func storesOnlyTheWorkspacesWindowsAndValidatesOnRead() {
        let store = FrameCacheStore()
        let harvest = WindowFrameHarvest(
            frames: [
                1: CGRect(x: 0, y: 0, width: 800, height: 1000),
                2: CGRect(x: 800, y: 0, width: 800, height: 1000),
                99: CGRect(x: 0, y: 0, width: 100, height: 100), // other workspace's window
            ],
            displays: [CGRect(x: 0, y: 0, width: 1600, height: 1000)]
        )
        store.store(workspace: "dev", windowIDs: [1, 2], harvest: harvest)

        let layout = store.layout(for: workspace("dev", windowIDs: [1, 2]))
        #expect(layout != nil)
        #expect(layout?.frames.keys.sorted() == [1, 2])

        // Window set changed while hidden → grid fallback.
        #expect(store.layout(for: workspace("dev", windowIDs: [1, 2, 3])) == nil)
        #expect(store.layout(for: workspace("dev", windowIDs: [1])) == nil)
    }

    @Test func unknownWorkspaceHasNoLayout() {
        let store = FrameCacheStore()
        #expect(store.layout(for: workspace("never-visited", windowIDs: [5])) == nil)
    }

    @Test func harvestWithNoRelevantWindowsIsIgnored() {
        let store = FrameCacheStore()
        let harvest = WindowFrameHarvest(
            frames: [99: CGRect(x: 0, y: 0, width: 100, height: 100)],
            displays: [CGRect(x: 0, y: 0, width: 1600, height: 1000)]
        )
        store.store(workspace: "dev", windowIDs: [1, 2], harvest: harvest)
        #expect(store.layout(for: workspace("dev", windowIDs: [1, 2])) == nil)
    }

    @Test func newerHarvestReplacesOlder() {
        let store = FrameCacheStore()
        let displays = [CGRect(x: 0, y: 0, width: 1600, height: 1000)]
        store.store(
            workspace: "dev", windowIDs: [1],
            harvest: WindowFrameHarvest(frames: [1: CGRect(x: 0, y: 0, width: 1600, height: 1000)], displays: displays)
        )
        store.store(
            workspace: "dev", windowIDs: [1],
            harvest: WindowFrameHarvest(frames: [1: CGRect(x: 0, y: 0, width: 800, height: 1000)], displays: displays)
        )
        let layout = store.layout(for: workspace("dev", windowIDs: [1]))
        #expect(layout?.frames[1]?.width == 0.5)
    }
}
