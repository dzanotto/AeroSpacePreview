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
show an about box, and quit.

> **Toolchain note**: the Makefile pins `TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault`.
> If you invoke `swift` directly and get SDK errors from a custom toolchain, do the same.

## Permissions

- **Screen Recording** — required for window thumbnails. The first launch triggers the
  system prompt (the app warms up ScreenCaptureKit at startup). If denied, the overlay
  still works fully with app-icon placeholder cards and shows a hint with a button to
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

Workspaces shown: occupied ones plus the focused one (even if empty), in AeroSpace's
natural sort order. Thumbnails are one-shot captures taken on summon; the overlay appears
as soon as AeroSpace state is in (~100 ms) and thumbnails pop in as captures complete
(~30 ms per window, serialized inside ScreenCaptureKit).

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
```

Each summon logs a timing line via NSLog (`make dev` to see it):
`summon — state 80 ms, capture 290 ms (8/8 windows)`.

## Requirements

- AeroSpace installed and running (`brew install --cask nikitabobko/tap/aerospace`);
  the CLI is discovered at `/opt/homebrew/bin/aerospace`, `/usr/local/bin/aerospace`,
  then `$PATH`.

See [SPEC.md](SPEC.md) for the full specification and [PLAN.md](PLAN.md) for the milestone
history and roadmap (live thumbnails are next).
