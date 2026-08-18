# Repository Guidelines

## Documentation

The Swift source is the only authority for behavior. `README.md` is the advanced-user entry
point, and `ARCHITECTURE.md` is the single home for technical, design, and architecture
explanations. Keep those documents aligned with behavioral changes, but resolve conflicts in
favor of code. Do not introduce milestone-based documentation or additional design files.

## Build, Test, and Development Commands

Use the Makefile so builds use the Xcode-bundled toolchain:

- `make build` compiles a release executable with SwiftPM.
- `make test` runs the complete Swift Testing suite.
- `make bundle` creates and ad-hoc signs `build/AeroSpacePreview.app`.
- `make run` builds and launches the menu-bar app detached.
- `make dev` runs it attached so `NSLog` timing and errors remain visible.
- `make clean` removes `.build/` and `build/` artifacts.

For focused debugging, run `.build/debug/AeroSpacePreview --dump` after a debug build.
AeroSpace must be installed and running for integration behavior.

## Source Organization and Style

Follow the ownership and dependency boundaries described in `ARCHITECTURE.md`. Keep production
code under `Sources/AeroSpacePreview/`, tests under `Tests/AeroSpacePreviewTests/`, bundle
metadata in `Resources/Info.plist`, and disposable technical experiments under `spikes/`.

Use four-space indentation, one primary type per file, `UpperCamelCase` types, `lowerCamelCase`
methods and properties, and descriptive enum cases. Keep platform imports explicit and preserve
actor/concurrency annotations. Prefer small, testable parsing or state helpers over embedding
logic in SwiftUI views. No formatter or linter is configured; match nearby code and limit
comments to non-obvious constraints.

## Testing Guidelines

Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, and `#expect`). Name files
`*Tests.swift`, group related cases in a suite, and give tests behavior-focused names such as
`focusedEmptyWorkspaceIsIncluded`. Add regression coverage for parsing, keyboard navigation,
layout, fallback behavior, and changed infrastructure boundaries. There is no enforced coverage
threshold; every behavioral change should include focused tests. Run `make test` before
submitting.

## Commit and Pull Request Guidelines

Use concise, verb-led commit subjects and keep each commit scoped to one coherent change. Pull
requests should explain user-visible behavior, implementation risks, and verification performed;
link relevant issues. Include screenshots or a short recording for overlay/menu changes, and
call out changes affecting Screen Recording permission, signing, hotkeys, or minimum macOS
support.
