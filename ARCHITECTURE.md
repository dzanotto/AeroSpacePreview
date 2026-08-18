# AeroSpacePreview architecture

> The Swift source is the only authoritative description of behavior. This document explains
> the current design and its constraints; when it disagrees with the implementation, the
> implementation wins and this document should be corrected.

## Scope

AeroSpacePreview is a macOS 14+ menu-bar application that presents a Mission Control-style
overlay for AeroSpace workspaces. It reads workspace state and performs focus actions through
the `aerospace` CLI. ScreenCaptureKit supplies the desktop background, initial window images,
live thumbnail updates, and the window geometry used for layout previews.

The current product is intentionally narrow:

- One overlay appears on the focused display.
- The Hyper+S hotkey is fixed in source.
- Layout history lasts only for the current process.
- There is no configuration file, drag-and-drop workspace editing, signed distribution, or
  notarized release pipeline.

## Package structure

The SwiftPM executable is organized by responsibility:

- `App/` contains process entry, application lifecycle, the menu-bar item, hotkey registration,
  debug commands, and overlay orchestration.
- `AeroSpace/` discovers and invokes the CLI, parses its output, and defines workspace models.
- `Capture/` owns ScreenCaptureKit capture, permission checks, placeholders, live-stream
  lifetime, and frame buffering.
- `Layout/` normalizes and caches window geometry.
- `UI/` contains the per-summon view model and SwiftUI views.
- `Diagnostics/` collects capture, delivery, latency, and process-resource telemetry.

Tests under `Tests/AeroSpacePreviewTests/` use Swift Testing and exercise pure rules plus
selected infrastructure boundaries.

## Ownership and dependencies

`AppDelegate` owns the three process-lifetime UI services: `OverlayController`,
`HotKeyManager`, and `StatusItemController`. It also starts a ScreenCaptureKit warm-up task so
the first overlay does not pay the full first-use cost.

`OverlayController` is main-actor isolated. It owns the panel, AeroSpace client, capture
service, frame cache, and diagnostics. `OverlayLifetime` models the active summon as `idle`,
`loading`, `visible`, or `hiding` and owns its capture, live-stream, and diagnostics tasks.
Opaque session IDs reject callbacks that arrive after dismissal or shutdown. Post-switch layout
harvests deliberately outlive normal dismissal, but the same lifetime owner cancels them during
application shutdown. `OverlayViewModel` owns per-summon presentation state. The SwiftUI layer
renders that state and emits `OverlayActions`; it does not call the CLI or ScreenCaptureKit
directly.

The rendered state deliberately has different update granularities:

- `OverlayContent` contains the immutable AeroSpace snapshot or an error.
- `ThumbnailStore` exposes stable per-window slots so one live image does not invalidate every
  tile.
- Layouts, the desktop background, keyboard selection, and the diagnostics snapshot publish
  independently.

## Application lifecycle

The executable handles `--dump` and `--dump-images` before starting AppKit. Normal launch creates
an accessory `NSApplication`, so the app has a menu-bar item but no Dock icon. The app delegate
registers Hyper+S, constructs the status menu, warms ScreenCaptureKit, and optionally summons the
overlay for `--show-on-launch`.

Summoning follows this sequence:

1. Select the focused display, create a new lifecycle session, and reject duplicate summons
   unless the lifetime is idle.
2. Fetch AeroSpace state.
3. Create the eager one-shot capture stream when Screen Recording is available.
4. Present the panel immediately with placeholders and any cached wallpaper/layouts.
5. Apply frame geometry, a fresh wallpaper, and window stills as they arrive.
6. After the one-shot pass finishes, start live streams for the same window set.
7. Stop the one-shot consumer and every live stream when the overlay dismisses or the app exits;
   session identity prevents their late results from reaching a replacement view model.

The panel dismisses on Escape, a backdrop click, loss of key status, a repeated toggle, or a
workspace/window action. Actions dismiss first, invoke the CLI asynchronously, and schedule a
layout harvest after the successful action.

## AeroSpace integration

`AeroSpaceClient` searches `/opt/homebrew/bin/aerospace`, `/usr/local/bin/aerospace`, and then
the process `PATH`. A snapshot is assembled from three independent CLI queries started with
structured `async let`:

- all windows, including each window's workspace;
- the focused workspace;
- the focused window, which may legitimately be absent.

The parser groups windows by workspace, ensures the focused workspace is present even when
empty, marks the focused window, and applies numeric-aware, case-insensitive ordering. Workspace
and window actions use the same asynchronous subprocess path as queries.

`AsyncProcessRunner` owns a child until the process has exited and both stdout and stderr have
reached EOF. It drains both pipes concurrently, limits stdout to 4 MiB and stderr to 256 KiB,
and applies the client's two-second command timeout. Cancellation, timeout, pipe failure, or
oversized output sends `SIGTERM`; a process still alive after a 300 ms grace period receives
`SIGKILL`. The runner still awaits process exit and both pipe drains before completing.

Only the complete, verified AeroSpace connection diagnostic maps to `serverNotRunning`.
Other nonzero exits remain command failures so unrelated server errors are not hidden.

## Capture pipeline

### One-shot pass

`CaptureService.captureStream` performs one `SCShareableContent` lookup and yields the requested
windows' geometry before any image events. It then uses a bounded task group for the desktop
background and window screenshots. At most four one-shot window captures are in flight because
ScreenCaptureKit has been observed to serialize much of this work; higher concurrency inflates
wall-clock time without improving throughput.

The overlay requests window images with a maximum dimension of 320 pixels. Missing, denied,
failed, or late images simply do not produce thumbnail events, so their existing placeholder
remains visible.

The per-window 600 ms timeout is best effort, not a strict return deadline.
`SCScreenshotManager.captureImage` exposes no supported cancellation token or stop operation,
and Swift task cancellation cannot guarantee that an in-progress framework call returns
promptly. Capture remains structured so objects retained by the framework stay alive until its
completion handler runs. The overlay itself never waits for pixels before presentation.

### Live pass

After the one-shot stream completes, the service attempts one desktop-independent `SCStream` per
capturable window, configured for a maximum dimension of 320 pixels and up to 30 frames per
second. The ScreenCaptureKit queue depth is its documented minimum of three.

Only `.started` and `.complete` frames are eligible for display. Idle, blank, suspended, stopped,
invalid, or failed frames leave the last good still in place. Each window has a serial conversion
pipeline that keeps at most one active and one pending pixel buffer, replacing stale pending work.
Converted images then enter a keyed delivery buffer that retains at most the newest pending image
per window while preserving a delivery slot for every distinct window.

`LiveThumbnailCapture` owns both the consumer stream and an explicit stop operation. Dismissal
signals the producer, finishes delivery, stops every `SCStream`, and cancels the consumer task;
task cancellation alone is not treated as sufficient stream cleanup.

### Permission and fallback behavior

Screen Recording permission is required for pixels and the rendered-wallpaper background, but
not for AeroSpace navigation. The app warms ScreenCaptureKit at launch, which also triggers the
system permission flow when needed. Without permission, workspace state and actions remain
usable, window cards use app-icon placeholders, and the overlay uses a visual-effect backdrop.
No Accessibility permission is required because the hotkey uses Carbon and all actions use the
AeroSpace CLI.

## Layout previews

AeroSpace keeps windows from hidden workspaces off-viewport. Those windows remain capturable,
but their current bounds do not describe their tiled layout. `FrameCacheStore` therefore records
geometry only when a workspace is known to be visible:

- during every summon for the currently focused workspace;
- roughly 300 ms after a workspace switch initiated by the overlay.

Frames are normalized against the display with the greatest total overlap. A cached layout is
used only when its window-ID set exactly equals the workspace's current window-ID set. Missing,
new, or closed windows invalidate the complete layout and make the tile use the uniform grid;
partial layouts are never mixed with the grid. The cache is in memory because window IDs usually
do not survive the owning applications.

## UI behavior

The grid uses up to four fixed columns so visual placement and keyboard navigation use the same
geometry. Left and right wrap; up and down move by a row and clamp. Typing selects by a
case-insensitive workspace-name prefix, and an exact unique name activates immediately.

Workspace tiles and their nested window thumbnails emit different intents: the tile switches
workspace, while a thumbnail focuses its window. The focused workspace/window treatment and the
keyboard selection treatment are separate visual states.

The fixed, non-scrolling grid is a known scalability limit for large workspace counts or small
displays.

## Diagnostics

Diagnostics are opt-in for each application session. The HUD samples at 2 Hz and reports stream
status, conversion and delivery rates, backlog, dropped/coalesced frames, latency, top window
bandwidth, CPU, physical memory footprint, and idle wakeups. Delivery latency ends at the
`ThumbnailStore`; it does not claim to measure physical display presentation.

The diagnostics subsystem is designed to stay off the hot path when disabled. When enabled, the
controller owns its sampling task and publishes one immutable diagnostics snapshot to the UI on
each interval. Dismissal logs a summary and stops sampling.

## Validated platform constraints

The following observations shaped the implementation. Measurements are historical data from the
original development machine, not performance guarantees:

- AeroSpace window IDs matched Core Graphics and ScreenCaptureKit window IDs on AeroSpace
  0.20.3-Beta, providing the join key between CLI state and captures.
- Hidden-workspace windows remained capturable even though their bounds were stacked
  off-viewport.
- Initial ScreenCaptureKit use cost roughly 370 ms; later captures were commonly tens of
  milliseconds per window and substantially serialized by the framework.
- A process using `SCContentFilter(desktopIndependentWindow:)` needs a window-server connection.
  The `--dump-images` path therefore initializes `NSApplication` before capture.
- The Makefile pins the Xcode-bundled Swift toolchain because the originally active custom
  toolchain was incompatible with the installed macOS SDK.

The spike programs under `spikes/` preserve the window-ID and hidden-capture experiments.

## Testing boundaries

Pure tests cover CLI parsing, natural ordering, keyboard rules, layout normalization and
validation, placeholders, frame-status filtering, frame coalescing, keyed delivery, and
diagnostic calculations. Infrastructure tests cover subprocess output, exit handling, timeout,
cancellation, and output limits.

ScreenCaptureKit behavior, permissions, AppKit panel lifecycle, menu integration, and physical
resource usage still require integration or manual testing on macOS. Tests should lock project
semantics without claiming guarantees that the public ScreenCaptureKit API does not make.
