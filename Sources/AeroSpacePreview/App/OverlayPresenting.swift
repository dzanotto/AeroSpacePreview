import CoreGraphics

struct OverlayDisplayTarget: Sendable {
    let displayID: CGDirectDisplayID?
}

@MainActor
protocol OverlayPresenting: AnyObject {
    var isVisible: Bool { get }

    func targetDisplay() -> OverlayDisplayTarget?
    func present(
        _ viewModel: OverlayViewModel,
        on target: OverlayDisplayTarget,
        onDismiss: @escaping @MainActor () -> Void
    ) -> Bool
    func dismiss(completion: @escaping @MainActor () -> Void)
    func clear()
}
