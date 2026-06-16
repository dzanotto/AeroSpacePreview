# AeroSpacePreview — Specification

A macOS companion app for [AeroSpace](https://github.com/nikitabobko/AeroSpace) that shows a
Mission Control-style, full-screen overlay previewing all AeroSpace workspaces with live window
thumbnails, and lets you switch workspace / focus windows from it.

AeroSpace deliberately bypasses native macOS Spaces and implements its own virtual workspaces,
so Mission Control shows nothing useful. This app fills that gap.

## 1. Product behavior

### Summoning & dismissing
- Pressing the global hotkey **Hyper+S** (⌘⌃⌥⇧ + S) toggles the overlay.
- The hotkey is registered by the app itself via the Carbon `RegisterEventHotKey` API
  (no Accessibility permission required). Hardcoded default; made configurable later.
- The overlay also dismisses on: **Esc**, clicking the dimmed background, losing key status,
  or completing any action (switch / focus).

### Overlay
- Full-screen borderless window on the focused monitor, above all other windows
  (`NSWindow.Level` ≥ `.popUpMenu`), with a dimmed/blurred backdrop
  (`NSVisualEffectView` behind the content).
- Shows a grid of **workspace tiles**, one per workspace.
- Workspaces shown: **occupied workspaces + the currently focused workspace** (even if empty),
  sorted by workspace name (AeroSpace's natural sort order).
- Each tile contains:
  - The **workspace name label** (e.g. `1`, `2`, `mail`).
  - **Window thumbnails**: one-shot screenshots of each window on that workspace, captured
    when the overlay is summoned (static while open).
  - A **focused-workspace highlight**: the focused workspace tile gets a distinct accent
    border; the focused window inside it is also subtly marked.
- Thumbnail layout inside a tile (since M7): a miniature of the workspace's real tiled
  layout, positioned from window frames cached the last time the workspace was visible
  (harvested on every summon, and ~300 ms after the overlay switches workspace). A tile
  falls back to a uniform aspect-preserving grid when no trustworthy layout exists: the
  workspace was never seen, Screen Recording is denied, or its window set changed while
  hidden (a cached layout is used only on an exact windowID-set match — no partial hybrids).
  - *Rationale for caching*: AeroSpace hides non-visible workspaces by moving their windows
    off-viewport, so the real tiled frames of hidden workspaces are not recoverable from
    current window bounds — only from frames observed while the workspace was visible.

### Interaction
- **Click a workspace tile** (background area) → `aerospace workspace <name>`, dismiss.
- **Click a window thumbnail** → `aerospace focus --window-id <id>`, dismiss.
- **Keyboard navigation** while the overlay is open:
  - Arrow keys move the workspace selection across the grid.
  - **Enter** switches to the selected workspace and dismisses.
  - Typing a workspace name prefix (e.g. `3`, or `m` for `mail`) selects it; if the match is
    unique, Enter (or a short auto-confirm on exact single-char names) switches.
  - **Esc** dismisses without action.

### Capture
- On summon: enumerate windows, capture **one fresh frame per window** with ScreenCaptureKit
  (`SCScreenshotManager.captureImage` with a desktop-independent window filter), then show
  the overlay. Target: overlay visible within ~150 ms on a typical workspace count.
- Captures run concurrently; a tile renders a placeholder (app icon on a neutral card) for any
  window whose capture fails or exceeds a 250 ms timeout — the overlay never blocks on a
  slow capture.
- Windows on hidden workspaces are off-screen but **not minimized**, so per-window capture is
  expected to work (verify in M1 — see Risks). Minimized/uncapturable windows get the
  placeholder card.

## 2. AeroSpace integration

All state comes from the `aerospace` CLI (path discovered via `/opt/homebrew/bin/aerospace`,
`/usr/local/bin/aerospace`, then `$PATH`; overridable later via config).

| Need | Command |
|---|---|
| Occupied workspaces | `aerospace list-workspaces --monitor all --empty no --format '%{workspace}'` |
| Focused workspace | `aerospace list-workspaces --focused` |
| Windows of a workspace | `aerospace list-windows --workspace <ws> --format '%{window-id}%{tab}%{app-name}%{tab}%{window-title}%{tab}%{app-bundle-id}'` |
| Focused window | `aerospace list-windows --focused --format '%{window-id}'` |
| Switch workspace | `aerospace workspace <ws>` |
| Focus window | `aerospace focus --window-id <id>` |

- Invocations use `Process` with explicit args (no shell), tab-separated `--format` output,
  and a 2 s timeout.
- AeroSpace's `window-id` is the CG window ID (AeroSpace derives it via `_AXUIElementGetWindow`),
  which is what `SCWindow.windowID` uses — this is the join key between AeroSpace state and
  ScreenCaptureKit. **Verified in M1** (see Risks).
- If the CLI is missing or the AeroSpace server isn't running, the overlay shows a single
  message tile ("AeroSpace not running / CLI not found at …") instead of crashing.

## 3. Architecture

Swift 6 / SwiftUI, macOS 14.0+ (required for `SCScreenshotManager`). Built as a SwiftPM
executable, assembled into a proper `.app` bundle by a `Makefile` (stable bundle ID +
ad-hoc signing so the Screen Recording TCC grant persists across rebuilds). No Xcode
project file; everything buildable from the CLI.

```
AeroSpacePreview/
├── Package.swift
├── Makefile                  # build, bundle, run, clean
├── Resources/Info.plist      # LSUIElement=true (agent app, no Dock icon)
└── Sources/AeroSpacePreview/
    ├── App/                  # @main, AppDelegate, hotkey registration, overlay controller
    ├── AeroSpace/            # CLI wrapper + model types (Workspace, Window)
    ├── Capture/              # ScreenCaptureKit one-shot capture service, permission flow
    └── UI/                   # Overlay SwiftUI views, keyboard handling, theming
```

Layers and dependencies (one direction only): `UI → ViewModel → {AeroSpaceClient, CaptureService}`.

- **AeroSpaceClient** (`AeroSpace/`): async functions wrapping the CLI; pure
  data out (`[Workspace]`, `[Window]`). No UI imports.
- **CaptureService** (`Capture/`): `func thumbnails(for windowIDs: [CGWindowID], maxPixel: Int) async -> [CGWindowID: CGImage]`.
  Handles `SCShareableContent` lookup, concurrent capture, downscaling (capture at roughly
  tile resolution, not full size), timeout, and the Screen Recording permission prompt /
  guidance state.
- **OverlayController** (`App/`): owns the `NSPanel`, toggling, key-window behavior, and the
  snapshot lifecycle: on summon → fetch AeroSpace state + fire captures → publish a single
  immutable `OverlaySnapshot` to the UI.
- **UI**: pure SwiftUI rendering of `OverlaySnapshot`, emitting user intents
  (`switchTo(workspace)`, `focus(windowID)`, `dismiss`) back to the controller.

### Permissions
- **Screen Recording** (TCC): required for thumbnails. First run triggers the system prompt;
  if denied, the overlay still works fully with placeholder cards and shows a one-line hint
  with a button opening System Settings → Privacy → Screen Recording.
- No Accessibility permission needed (Carbon hotkey + CLI do not require it).

## 4. Non-goals (v1)

- Multi-monitor (single focused monitor only; the data model keeps a `monitor` field so this
  can be added without reshaping).
- Live/streaming thumbnails, drag-and-drop of windows between workspaces.
- Config file, hotkey customization UI, menu bar icon.
- Distribution: signing with a Developer ID, notarization, Homebrew. (Architecture stays
  release-clean; see Scope.)

## 5. Scope & quality bar

Personal tool first, architected for a later open-source release: clean module boundaries,
no hardcoded user-specific paths beyond documented defaults, README with build instructions.
Distribution polish is deferred.

## 6. Future enhancements (explicitly out of v1)

1. Multi-monitor: per-monitor overlay with that monitor's workspaces.
2. ~~Layout-faithful previews~~ — shipped in M7. Remaining stretch pieces: persisting the
   frame cache across app restarts, and an `exec-on-workspace-change` hook so harvesting
   also happens outside the overlay (documented in README, not wired).
3. Config file (TOML, like AeroSpace) for hotkey, shown workspaces, theming.
4. Menu bar icon, live thumbnails, drag windows between workspaces.
5. Signed/notarized releases + Homebrew cask.

## 7. Risks & verification items

| # | Risk | Status (M0 spikes, 2026-06-10, AeroSpace 0.20.3-Beta) |
|---|---|---|
| R1 | AeroSpace `window-id` might not equal CGWindowID | ✅ **Verified**: every `aerospace list-windows` ID matched a `CGWindowListCopyWindowInfo` entry with the correct owning app (`spikes/r1_window_ids.swift`). |
| R2 | ScreenCaptureKit may return blank frames for off-viewport windows of hidden workspaces | ✅ **Verified**: hidden-workspace windows capture with real, current content (`spikes/r2_capture.swift`). ~40–65 ms per capture after a ~370 ms first-capture warm-up — warm up the SCK session at app launch, not on first summon. |
| R3 | Hyper+S may collide with an existing aerospace.toml binding | ✅ **Verified** (M6, 2026-06-12): no Hyper/`cmd-ctrl-alt-shift` bindings in `~/.config/aerospace/aerospace.toml`. If registration ever fails, the app logs it and runs hotkey-less; the combination is a single constant in `AppDelegate.swift`. |
| R4 | `aerospace focus --window-id` availability | ✅ **Verified** on 0.20.3-Beta, along with all `--format` interpolations used in §2. |
| R5 | Capture latency with many windows (>20) | Mitigated by design (concurrent capture, downscaling, 250 ms timeout, placeholders); re-measure in M3. |

### M0 findings that bind the implementation
- Hidden-workspace window bounds confirm AeroSpace stacks them off-viewport (all at the same
  corner coordinates) — hence the frame cache + grid fallback design in §1: hidden-workspace
  layouts come only from frames observed while visible.
- `SCContentFilter(desktopIndependentWindow:)` crashes in a process without a window-server
  connection; a real `NSApplication`-based app is fine, but any CLI test harness must touch
  `NSApplication.shared` first.
- The machine's default Swift toolchain (`~/Library/Developer/Toolchains/swift-6.1.2`) fails
  to compile against the current macOS SDK. Build with the Xcode toolchain:
  `TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault xcrun swift build` (encode this in the Makefile).
