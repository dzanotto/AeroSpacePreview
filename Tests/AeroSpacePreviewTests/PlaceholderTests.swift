import Testing
import CoreGraphics
@testable import AeroSpacePreview

@Suite struct PlaceholderRendering {
    @Test func rendersCardWithKnownApp() {
        let image = PlaceholderRenderer.render(bundleID: "com.apple.finder",
                                               size: CGSize(width: 320, height: 200))
        #expect(image?.width == 320)
        #expect(image?.height == 200)
        #expect(PlaceholderRenderer.appIcon(bundleID: "com.apple.finder") != nil)
    }

    @Test func rendersCardForUnknownBundleID() {
        // Unknown app: still a card, just without an icon.
        let image = PlaceholderRenderer.render(bundleID: "com.does.not.exist",
                                               size: CGSize(width: 100, height: 80))
        #expect(image != nil)
        #expect(PlaceholderRenderer.appIcon(bundleID: "com.does.not.exist") == nil)
    }
}
