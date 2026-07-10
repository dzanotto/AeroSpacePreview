# Repository Guidelines

## Project Structure & Module Organization

`AeroSpacePreview` is a Swift 6 executable package targeting macOS 14+. Production code lives in `Sources/AeroSpacePreview/`, grouped by responsibility: `App/` contains lifecycle, menu bar, and hotkey wiring; `AeroSpace/` wraps and parses the AeroSpace CLI; `Capture/` handles ScreenCaptureKit and fallbacks; `Layout/` caches window geometry; and `UI/` contains SwiftUI views and overlay state. Tests live in `Tests/AeroSpacePreviewTests/`. Keep bundle metadata in `Resources/Info.plist`; use `spikes/` only for disposable technical experiments. `SPEC.md` defines behavior and `PLAN.md` records milestones.

## Build, Test, and Development Commands

Use the Makefile so builds use the Xcode-bundled toolchain:

- `make build` compiles a release executable with SwiftPM.
- `make test` runs the complete Swift Testing suite.
- `make bundle` creates and ad-hoc signs `build/AeroSpacePreview.app`.
- `make run` builds and launches the menu bar app detached.
- `make dev` runs it attached so `NSLog` timing and errors remain visible.
- `make clean` removes `.build/` and `build/` artifacts.

For focused debugging, run `.build/debug/AeroSpacePreview --dump` after a debug build. AeroSpace must be installed and running for integration behavior.

## Coding Style & Naming Conventions

Follow existing Swift conventions: four-space indentation, one primary type per file, `UpperCamelCase` types, `lowerCamelCase` methods and properties, and descriptive enum cases. Keep platform imports explicit and preserve actor/concurrency annotations. Prefer small, testable parsing or state helpers over embedding logic in SwiftUI views. No formatter or linter is configured; match nearby code and keep comments limited to non-obvious constraints.

## Testing Guidelines

Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, and `#expect`). Name files `*Tests.swift`, group related cases in a suite, and give tests behavior-focused names such as `focusedEmptyWorkspaceIsIncluded`. Add regression coverage for parsing, keyboard navigation, layout, and fallback behavior. There is no enforced coverage threshold; every behavioral change should include focused tests. Run `make test` before submitting.

## Commit & Pull Request Guidelines

Recent commits use concise, verb-led subjects, for example `Record M8 menu actions verified working`, with milestone identifiers when applicable. Keep each commit scoped to one coherent change. Pull requests should explain user-visible behavior, implementation risks, and verification performed; link relevant issues or `PLAN.md` milestones. Include screenshots or a short recording for overlay/menu changes, and call out changes affecting Screen Recording permission, signing, hotkeys, or minimum macOS support.
