# AeroSpacePreview — Implementation Plan

Companion to [SPEC.md](SPEC.md). Six milestones, each ending in something runnable.
Estimated sizes are relative (S/M/L), not time promises.

> **v1 is CLOSED (2026-06-19).** M0–M7 shipped; the daily-driving soak week
> (2026-06-12 → 2026-06-19) passed without crashes or stuck overlays, and M7's
> layout previews verified in practice. M8 (menu bar) and M9 (live thumbnails) are
> **out of v1** by SPEC §4 — they're the first post-v1 work, not v1 blockers.

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

## M6 — Polish & hardening (M) ✅ DONE 2026-06-12 (soak week passed 2026-06-19)

- Re-entrancy: hotkey while overlay open = dismiss; ignore summon while a snapshot is loading.
  (Both already held from M1/M4 guards — verified by inspection, no changes needed.)
- Edge cases: 0 occupied workspaces and 1 workspace were already covered (parser tests);
  added: workspace-name label truncation for very long names; bounded capture concurrency
  (4 in flight, 600 ms per-window timeout — at 8/250 ms the back of a 9-window queue
  timed out spuriously because SCK serializes and the timer ticks while queued).
  Window-closed-between-snapshot-and-click already failed silently + dismissed.
- Performance pass (measured on the dev machine, 7–8 windows):
  - Captures cost ~30 ms/window and are **serialized inside ScreenCaptureKit** — resolution
    (320/640/1280 maxPixel: no difference) and concurrency are not levers. The <150 ms
    full-capture target is unreachable for 10+ windows.
  - Fix: **present-first summon** — overlay appears as soon as CLI state is in; captures
    start in parallel with presentation and stream in progressively, one thumbnail at a
    time (`CaptureService.thumbnailStream`, published per-window by the view model with a
    short crossfade). Placeholders cover whatever hasn't landed. This is also the
    thumbnail plumbing M9 needs.
  - CLI state fetch was 170–290 ms (3 sequential invocations à ~60–95 ms); now the three
    queries run concurrently → ~100 ms wall clock to overlay-visible.
  - Each summon NSLogs `state X ms, capture Y ms (n/m windows)` for ongoing measurement.
- README written (build, permissions, hotkey/R3, AeroSpace 0.20.3-Beta, debug flags);
  R3 closed in SPEC §7 (no Hyper bindings in aerospace.toml, checked 2026-06-12).
- `git init` + `.gitignore` were done at M1.

**Exit criteria**: a week of daily-driving without crashes or stuck overlays — ✅ met
(2026-06-12 → 2026-06-19, no crashes or stuck overlays).

## M7 — Layout-faithful previews via frame caching (L) ✅ CODE DONE 2026-06-12

Replaces the uniform thumbnail grid inside a tile with a miniature of the workspace's real
tiled layout, for every workspace we've seen at least once. (SPEC §1 rationale + §6.2.)

Implemented as planned; notes: `Layout/FrameCacheStore.swift` holds the cache plus pure
`LayoutMath` (normalize / display-pick / validate / letterbox — all unit-tested);
`CaptureService.captureStream` now yields a `.frames` event (piggybacked harvest) before
thumbnails, plus a standalone `windowFrames(for:)` used by the post-switch harvest
(`AeroSpaceClient.fetchFocusedWorkspaceWindows`, 300 ms after each overlay action).
Layouts publish separately from the immutable snapshot (same pattern as thumbnails), so a
tile can upgrade grid→layout when summon-time frames land. JSON persistence and
`exec-on-workspace-change` remain unwired (documented in README). ✅ Verified during the
soak week (2026-06-19): focused + visited workspaces render as layouts, never-visited and
hidden-set-changed workspaces fall back to the grid.

- **Frame source — piggyback on SCK**: `SCWindow.frame` is already available from the
  `SCShareableContent` lookup `CaptureService` does on every summon — no new API, no new
  permission. Frames are only real for the *currently visible* workspace (hidden ones are
  stacked off-viewport, per M0), so harvest only windows of the focused workspace.
- **Harvest moments**:
  1. On every summon (focused workspace's frames are accurate at that instant).
  2. ~300 ms after the overlay switches workspace, run a background harvest
     (`list-windows --focused` + one `SCShareableContent` call) so the newly revealed
     workspace gets cached — normal use of the app populates the cache by itself.
  3. Stretch (opt-in, documented not wired): `exec-on-workspace-change` in aerospace.toml
     pinging the app for harvest-on-every-switch even outside the overlay.
- **`FrameCacheStore`** (new, in `Capture/` or its own `Layout/`): workspace name →
  `[CGWindowID: CGRect]` normalized to the monitor frame, plus a timestamp. In-memory first;
  JSON persistence in Application Support as a stretch goal (windowIDs die with the owning
  apps, so persistence helps only across *our* restarts — validate before use).
- **Validation rule**: a tile uses the cached layout only if the cached windowID set equals
  the workspace's current window set; any mismatch (window opened/closed while hidden) falls
  back to the existing uniform grid for that tile. Simple and predictable; no partial hybrids.
- **Rendering**: `WorkspaceLayoutView` alongside the grid in `WorkspaceTileView.swift` —
  scale the monitor rect into the tile, position thumbnails at their normalized frames.
  The focused workspace always renders layout-faithful (its frames are always fresh).
- Unit tests: normalization round-trip, validation rule, grid fallback selection.

**Exit criteria**: focused + previously visited workspaces render as miniature layouts;
a never-visited workspace falls back to the grid; opening/closing a window on a hidden
workspace falls back to the grid instead of showing a wrong layout.

## M8 — Menu bar icon (S) — POST-v1 ✅ DONE 2026-06-22

The app is `LSUIElement` — there was no way to see it's running or quit it without `kill`.
Implemented as planned in `App/StatusItemController.swift` (owned by `AppDelegate` next to
`HotKeyManager`):

- `NSStatusItem` with the template SF Symbol `square.grid.2x2`, menu:
  - "Show Workspace Preview  ⌘⌃⌥⇧S" → `overlay.toggle()` (same path as the hotkey; the
    Hyper modifiers are display-only since the global Carbon hotkey already handles it).
  - "Launch at Login" → `SMAppService.mainApp` register/unregister; the checkmark is
    refreshed from `.status` via `NSMenuDelegate.menuNeedsUpdate` each time the menu opens.
  - "About AeroSpacePreview" → `orderFrontStandardAboutPanel` (version read from the bundle
    Info.plist; `NSApp.activate` first so the panel comes to front for the accessory app).
  - "Quit AeroSpacePreview".

**Exit criteria**: icon visible, all four menu actions work, login item survives reboot.
Release build and bundle are clean; the `square.grid.2x2` icon is confirmed visible in the
menu bar, and all four menu actions (Show Preview, Launch at Login, About, Quit) were
manually verified working. Login-item survives-reboot is the only check left to confirm in
normal use.

## M9 — Adaptive live thumbnails while the overlay is open (M) — POST-v1 ✅ CODE DONE 2026-07-10

- **Change-aware `SCStream` capture**: after the progressive one-shot pass supplies the
  initial stills, one desktop-independent stream starts per capturable window at up to
  30 fps. ScreenCaptureKit emits `.complete` frames for changed content and `.idle` for
  static content; only `.started`/`.complete` frames are published. Static thumbnails
  therefore stay visually frozen with no motion classifier or probe delay.
- Streams are intentionally uncapped: every animated window can refresh concurrently.
  Output stays at the existing 640-pixel thumbnail resolution with a two-frame queue so
  stale frames do not build up.
- `ThumbnailStore` gives each window a stable observable slot. A live frame redraws only
  its thumbnail rather than invalidating the whole overlay grid; `OverlaySnapshot` remains
  immutable for workspace/focus/layout state.
- `OverlayController` owns the complete one-shot → live lifecycle. Dismissal cancels the
  consumer and stops every stream; cleanup is idempotent and also handles cancellation
  racing asynchronous startup.
- Idle, blank, suspended, stopped, failed, or uncapturable streams keep the last good still
  instead of flashing a placeholder. The AeroSpace state/window set remains static until
  the next summon.
- Swift Testing coverage locks frame-status filtering, stable per-window slots,
  last-good-frame retention, and cancellation cleanup.

**Exit criteria**: a video playing on a hidden workspace visibly updates in the open
overlay at up to 30 fps; static windows remain still; no flicker; CPU/GPU and memory with
several simultaneous animated windows stay acceptable. Build and automated tests pass;
visual and resource checks remain to be recorded during normal use.

## Deferred (tracked, not planned)

Config file (TOML) → multi-monitor → drag-and-drop → notarized releases. See SPEC.md §6.

## Order & dependencies

```
M0 ─► M1 ─► M2 ─► M3 ─► M4 ─► M5 ─► M6 ─► M7 ─► M9
            │                          └── M8 is independent (any time after M1)
            └── M2 and M3 are independent after M1; can be built in either order
```

M7 before M9: live refresh should land on top of the final tile rendering (layout view),
not the grid it replaces.
