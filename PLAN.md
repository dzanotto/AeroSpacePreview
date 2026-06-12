# AeroSpacePreview — Implementation Plan

Companion to [SPEC.md](SPEC.md). Six milestones, each ending in something runnable.
Estimated sizes are relative (S/M/L), not time promises.

## M0 — Feasibility spikes (S) ✅ DONE 2026-06-10

All three risks retired (spike code in `spikes/`, results in SPEC.md §7):

1. **R1 — window-id join key**: ✅ AeroSpace IDs are CGWindowIDs (`spikes/r1_window_ids.swift`).
2. **R2 — hidden-workspace capture**: ✅ real content captured, ~40–65 ms/window after a
   ~370 ms first-capture warm-up (`spikes/r2_capture.swift`, sample output in `spikes/out/`).
3. **R4 — CLI surface**: ✅ `focus --window-id` + all `--format` interpolations work on
   AeroSpace 0.20.3-Beta.

Carry-overs for M1: warm up SCK at app launch; Makefile must build with
`TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault` (default toolchain on this machine is broken
against the current SDK).

## M1 — App skeleton + hotkey + empty overlay (M) ✅ DONE 2026-06-11

- `Package.swift` (swift-tools 6.0, macOS 14 platform), `Sources/` layout per spec §3.
- `Makefile`: `make build` → release binary; `make bundle` → `AeroSpacePreview.app` with
  `Info.plist` (`LSUIElement=true`, stable bundle ID `com.dariozanotto.aerospacepreview`),
  ad-hoc codesign; `make run`.
- AppDelegate-based agent app (no Dock icon), Carbon `RegisterEventHotKey` for ⌘⌃⌥⇧S.
- `OverlayController` with a borderless, full-screen, key-able `NSPanel` on the focused
  screen showing a placeholder SwiftUI view; toggles on hotkey, dismisses on Esc / click /
  losing key status.

**Exit criteria**: `make run`; Hyper+S toggles a dimmed full-screen overlay; Esc closes it.

## M2 — AeroSpace data layer (M) ✅ DONE 2026-06-11

- `AeroSpaceClient`: CLI discovery, `Process`-based runner (no shell, 2 s timeout),
  tab-separated `--format` parsing.
- Model types: `Workspace { name, isFocused, windows }`, `Window { id: CGWindowID, appName,
  title, bundleID, isFocused }`.
- `fetchSnapshot()` → occupied + focused workspaces with their windows, natural-sorted.
- Error taxonomy: CLI not found / server not running / parse failure → typed errors.
- Unit tests for the parser (fixture strings) and natural sort.

**Exit criteria**: a debug command (`AeroSpacePreview --dump`) prints the full snapshot as JSON.

## M3 — Capture service (M) ✅ DONE 2026-06-11
(2/2 open windows captured in 70 ms post-warm-up; re-measure the <150 ms/10-window
target in M6 when more windows are open — captures are concurrent, so it should hold.)

- `CaptureService.thumbnails(for:maxPixel:)`: `SCShareableContent.excludingDesktopWindows`
  lookup, concurrent per-window `SCScreenshotManager` captures, downscale to tile resolution,
  250 ms per-window timeout, results keyed by `CGWindowID`.
- Screen Recording permission flow: detect denial, expose a state the UI can render
  (hint + button to open System Settings pane).
- Placeholder generation: app icon (via `NSWorkspace`/bundle ID) on a neutral card.

**Exit criteria**: `--dump-images <dir>` writes a thumbnail (or placeholder) per window;
overlay-relevant capture pass for ~10 windows completes in <150 ms on the dev machine.

## M4 — Overlay UI (L) ✅ DONE 2026-06-11
(Click-to-switch and click-to-focus were wired here too since the client calls
were one-liners; M5 is keyboard navigation + selection model.)

- `OverlaySnapshot` (immutable: workspaces + thumbnails + focus info) assembled by the
  controller on summon; published to SwiftUI.
- Workspace tile grid: adaptive columns, tile = name label + thumbnail grid
  (aspect-ratio-preserving cells), focused-workspace accent border, focused-window marker.
- Backdrop: dimmed `NSVisualEffectView`; summon/dismiss fade (~120 ms).
- Degraded states: "AeroSpace not running" tile; permission-denied hint bar.

**Exit criteria**: Hyper+S shows real workspaces with real thumbnails; visuals match spec §1.

## M5 — Interaction (M) ✅ DONE 2026-06-11

- Click tile → `workspace <name>` + dismiss; click thumbnail → `focus --window-id` + dismiss.
- Keyboard: arrow-key selection model (grid-aware), Enter activates, Esc dismisses,
  type-to-select by workspace-name prefix.
- Selection visuals distinct from the focused-workspace highlight.

**Exit criteria**: full loop usable daily without touching the mouse; mouse-only also works.

## M6 — Polish & hardening (M)

- Re-entrancy: hotkey while overlay open = dismiss; ignore summon while a snapshot is loading.
- Edge cases: 0 occupied workspaces, 1 workspace, >30 windows, very long titles/names,
  window closed between snapshot and click (action fails silently + dismiss).
- Performance pass on summon latency (measure, then tune capture resolution/concurrency).
- README: build instructions, permission setup, hotkey note (R3), AeroSpace version tested.
- `git init` + sensible `.gitignore` (if not done at M1 — do it at M1).

**Exit criteria**: a week of daily-driving without crashes or stuck overlays.

## Deferred (tracked, not planned)

Multi-monitor → layout-faithful previews (frame caching) → config file → menu bar icon →
live thumbnails → drag-and-drop → notarized releases. See SPEC.md §6.

## Order & dependencies

```
M0 ─► M1 ─► M2 ─► M3 ─► M4 ─► M5 ─► M6
            └── M2 and M3 are independent after M1; can be built in either order
```
