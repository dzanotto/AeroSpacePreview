# AeroSpacePreview

AeroSpacePreview is a Mission Control-style workspace previewer for the
[AeroSpace](https://github.com/nikitabobko/AeroSpace) tiling window manager. Press Hyper+S
(⌘⌃⌥⇧S) to open a full-screen overview of occupied workspaces, see live window thumbnails,
and switch workspace or focus a window with the keyboard or mouse.

AeroSpace implements virtual workspaces outside native macOS Spaces, so the system Mission
Control view cannot represent them. AeroSpacePreview fills that gap.

## Requirements

- macOS 14 or later.
- AeroSpace installed and running. The app has been exercised with AeroSpace 0.20.3-Beta.
- Xcode with its bundled Swift toolchain for building from source.

The CLI is discovered at `/opt/homebrew/bin/aerospace`, `/usr/local/bin/aerospace`, and then on
`PATH`. Homebrew users can install AeroSpace with:

```sh
brew install --cask nikitabobko/tap/aerospace
```

## Build and run

There is no Xcode project or packaged release. Build the application from the repository with
the Makefile:

```sh
make run
```

This creates an ad-hoc-signed `build/AeroSpacePreview.app` and launches it. The app is an agent:
it has no Dock icon and remains available through the `square.grid.2x2` menu-bar icon.

Other development targets are:

```sh
make build    # compile the release executable
make bundle   # build, assemble, and ad-hoc sign the application bundle
make dev      # run attached so NSLog output remains visible
make test     # run the Swift Testing suite
make clean    # remove .build/ and build/
```

The Makefile pins `TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault`. Invoking `swift` directly
can select an incompatible custom toolchain, so the Makefile targets are the supported workflow.

## Permissions

Screen Recording is required for window images and the rendered-wallpaper backdrop. The first
launch warms ScreenCaptureKit and may trigger the macOS permission prompt. If permission is
denied, the overlay still supports navigation, using app-icon cards and a visual-effect backdrop.
It also offers a shortcut to System Settings → Privacy & Security → Screen Recording.

Accessibility permission is not required. The global hotkey uses the Carbon hotkey API, and
workspace/window actions go through the AeroSpace CLI.

## Using the overlay

Hyper+S is registered by AeroSpacePreview itself; do not bind the same combination in
`aerospace.toml`. If another application already owns it, AeroSpacePreview logs the failure and
continues running without a global hotkey. The menu-bar command can still open the overlay.

| Input | Effect |
|---|---|
| Hyper+S | Toggle the overlay |
| Click a workspace tile | Switch to that workspace |
| Click a window thumbnail | Focus that window |
| Left or right arrow | Move selection, wrapping at the ends |
| Up or down arrow | Move by one grid row, clamping at the edges |
| Type a workspace-name prefix | Select a match; an exact unique name switches immediately |
| Enter | Switch to the selected workspace |
| Esc or click the backdrop | Dismiss without an action |

By default, the overlay includes every occupied workspace plus the focused workspace when it is
empty. Enable Show Empty Workspaces from the menu-bar item to include every AeroSpace workspace;
the choice persists across launches. Workspaces use AeroSpace's natural name order. Workspace
tiles fill up to four columns before continuing on another row. Initial window images appear
progressively, then changed window content continues updating at up to 30 fps while static
thumbnails remain still.

When AeroSpacePreview has observed a workspace while it was visible, its tile mirrors the real
tiled layout. A uniform thumbnail grid is used after launch for unseen workspaces and whenever a
hidden workspace's window set has changed. Layout observations are kept only until the app quits.

The backdrop uses a fresh image of the focused display's rendered wallpaper, lightly blurred and
dimmed. A cached image prevents the real windows behind the panel from flashing while the next
background arrives.

## Menu-bar commands

The menu-bar item provides:

- Show Workspace Preview.
- Show Empty Workspaces, disabled by default and persisted across launches.
- Show Diagnostics, retained for the current app session.
- Launch at Login.
- About AeroSpacePreview.
- Quit AeroSpacePreview.

## Diagnostics and debug commands

Diagnostics are off by default and remain available in release builds. Enable them from the menu
or launch with `--debug-hud`. The HUD shows capture activity, conversion and delivery rates,
backlog, latency, high-bandwidth windows, CPU, memory footprint, and idle wakeups. Each dismissal
also writes a summary to NSLog; use `make dev` to keep logs visible.

The executable accepts these development commands:

```sh
AeroSpacePreview --dump               # print the AeroSpace snapshot as JSON and exit
AeroSpacePreview --dump-images DIR    # write a thumbnail or placeholder per window and exit
AeroSpacePreview --show-on-launch     # summon the overlay immediately
AeroSpacePreview --debug-hud          # start with diagnostics enabled
```

After `make build`, replace `AeroSpacePreview` above with
`.build/release/AeroSpacePreview`. After `make bundle`, the executable is also available at
`build/AeroSpacePreview.app/Contents/MacOS/AeroSpacePreview`.

## Current limitations

- The overlay targets the focused display rather than presenting independently on every display.
- The hotkey and appearance are not configurable.
- Large workspace counts can outgrow the fixed, non-scrolling tile grid.
- Layout history does not observe workspace switches performed outside this overlay.
- There is no notarized distribution or installer.

## Technical and contributor information

The Swift source is the only authoritative description of behavior. See
[ARCHITECTURE.md](ARCHITECTURE.md) for a consolidated explanation of the current design and
[AGENTS.md](AGENTS.md) for repository contribution conventions.
