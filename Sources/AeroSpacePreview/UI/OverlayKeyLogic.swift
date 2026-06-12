/// Pure keyboard-navigation rules for the workspace grid — no AppKit, fully
/// unit-testable.
enum OverlayKeyLogic {
    /// The tile grid uses a fixed column count (not adaptive) so navigation
    /// and layout can't disagree about geometry.
    static func columns(for count: Int) -> Int {
        min(max(count, 1), 4)
    }

    enum Arrow {
        case left, right, up, down
    }

    /// Left/right wrap around; up/down move by one row and clamp at the edges.
    static func move(index: Int, count: Int, columns: Int, arrow: Arrow) -> Int {
        guard count > 0 else { return 0 }
        switch arrow {
        case .left:
            return (index - 1 + count) % count
        case .right:
            return (index + 1) % count
        case .up:
            let target = index - columns
            return target >= 0 ? target : index
        case .down:
            let target = index + columns
            return target < count ? target : index
        }
    }

    enum PrefixResult: Equatable {
        case noMatch
        case select(Int)
        /// The prefix equals exactly one full workspace name — switch now,
        /// no Enter needed (makes numbered workspaces feel instant).
        case activate(Int)
    }

    static func prefixMatch(_ prefix: String, names: [String]) -> PrefixResult {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return .noMatch }
        let matches = names.indices.filter { names[$0].lowercased().hasPrefix(needle) }
        guard let first = matches.first else { return .noMatch }
        if matches.count == 1, names[first].lowercased() == needle {
            return .activate(first)
        }
        return .select(first)
    }
}
