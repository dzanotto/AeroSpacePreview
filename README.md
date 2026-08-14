# AeroSpacePreview

A Mission Control-style workspace previewer for the [AeroSpace](https://github.com/nikitabobko/AeroSpace)
tiling window manager. Press **Hyper+S** (⌘⌃⌥⇧S) to get a full-screen overlay of all your
workspaces with live window thumbnails; click (or type / arrow around) to switch workspace or
focus a window.

AeroSpace bypasses native macOS Spaces, so Mission Control shows nothing useful. This fills
that gap.

Tested against **AeroSpace 0.20.3-Beta** on **macOS 14+** (macOS 14 is the hard floor —
the capture path needs `SCScreenshotManager`).

## Build & run

No Xcode project — everything goes through SwiftPM and the Makefile:

```sh
make bundle   # release build + assemble build/AeroSpacePreview.app (ad-hoc signed)
make run      # bundle + launch detached
make dev      # bundle + run attached to the terminal (NSLog output visible)
swift test    # unit tests
```

The app is an agent (`LSUIElement`): nothing appears in the Dock. It lives in the menu bar
as a `square.grid.2x2` icon whose menu can show the overlay, toggle **Launch at Login**,
toggle the session-only **Show Diagnostics** HUD, show an about box, and quit.

> **Toolchain note**: the Makefile pins `TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault`.
> If you invoke `swift` directly and get SDK errors from a custom toolchain, do the same.

## Permissions

- **Screen Recording** — required for window thumbnails and the rendered-wallpaper
  backdrop. The first launch triggers the system prompt (the app warms up ScreenCaptureKit
  at startup). If denied, the overlay still works fully with app-icon placeholder cards
  and the visual-effect fallback, and shows a hint with a button to
  System Settings → Privacy & Security → Screen Recording. The bundle ID and signature
  are stable across rebuilds, so the grant persists.
- **No Accessibility permission** is needed: the hotkey uses the Carbon
  `RegisterEventHotKey` API and all window-manager state comes from the `aerospace` CLI.

## Hotkey

Hyper+S (⌘⌃⌥⇧S) is registered by the app itself — do **not** bind it in `aerospace.toml`.
If registration fails at launch (another app owns the combination), the app logs
`failed to register Hyper+S` and keeps running without a hotkey. Checked 2026-06-12: the
default AeroSpace config and this machine's config have no Hyper bindings, so no collision.
The combination is a single constant in `AppDelegate.swift` if you need to change it.

## Usage

| Input | Effect |
|---|---|
| Hyper+S | toggle the overlay |
| click tile / thumbnail | switch workspace / focus that window |
| arrow keys | move tile selection (←/→ wrap, ↑/↓ clamp) |
| type a name prefix | select the matching workspace; a unique exact match switches immediately |
| Enter | switch to selected workspace |
| Esc / click backdrop | dismiss |
| menu-bar **Show Diagnostics** | show/hide the diagnostics HUD for this app session |

Workspaces shown: occupied ones plus the focused one (even if empty), in AeroSpace's
natural sort order. The backdrop is a fresh still of the monitor's currently rendered
wallpaper, lightly blurred and dimmed; the previous still is cached between summons to
avoid flashing the windows behind the overlay. An initial one-shot pass lets thumbnails
pop in progressively (~30 ms per window, serialized inside ScreenCaptureKit). It then
transitions to change-aware streams at up to 30 fps: animated windows update in real time
while static windows keep their still image.

### Layout previews

Tiles render a miniature of the workspace's real tiled layout when the app has seen that
workspace at least once: window frames are cached on every summon and again ~300 ms after
you switch workspace through the overlay, so normal use populates the cache by itself.
A tile falls back to a uniform thumbnail grid when no trustworthy layout exists — the
workspace hasn't been visible since the app launched, or its window set changed while it
was hidden. The cache is in-memory only; a restart starts over from grids.

If you want the cache to also pick up workspace switches made *outside* the overlay
(plain `alt-1`-style bindings), a future `exec-on-workspace-change` hook in
`aerospace.toml` could ping the app to harvest on every switch — documented as a stretch
goal in PLAN.md M7, not wired up yet.

## Debug flags

```sh
AeroSpacePreview --dump               # print the AeroSpace snapshot as JSON and exit
AeroSpacePreview --dump-images DIR    # write a thumbnail/placeholder PNG per window and exit
AeroSpacePreview --show-on-launch     # summon the overlay immediately (testing)
AeroSpacePreview --debug-hud          # enable the diagnostics HUD (also available from the menu)
```

Diagnostics are off by default and remain available in release builds. The compact top-right
HUD samples at 2 Hz and reports live-stream/input, conversion, UI-delivery/backlog, latency,
top-window bandwidth, CPU, memory-footprint, and idle-wakeup metrics. “UI” is delivery to the
SwiftUI thumbnail store, not proof of physical display presentation. The menu checkmark is
session-only; toggling it updates an open overlay or takes effect on the next summon.

Each summon logs timing and live-stream startup via NSLog (`make dev` to see it):
`summon — state 80 ms, capture 290 ms (8/8 windows)` and
`live capture — 8/8 streams at up to 30 fps`.

## Requirements

- AeroSpace installed and running (`brew install --cask nikitabobko/tap/aerospace`);
  the CLI is discovered at `/opt/homebrew/bin/aerospace`, `/usr/local/bin/aerospace`,
  then `$PATH`.

See [SPEC.md](SPEC.md) for the original v1 specification and [PLAN.md](PLAN.md) for the
milestone history and deferred roadmap.
