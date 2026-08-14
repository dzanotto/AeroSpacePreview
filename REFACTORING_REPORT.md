# Refactoring and Cleanup Review

Reviewed: 2026-08-14
Scope: production sources, tests, Swift package/build configuration, and project documentation
Review method: static, read-only inspection; tests were not run during the review to avoid updating generated build artifacts

## Purpose

This document records potential refactors, simplifications, and cleanups for later investigation. It is a working backlog, not a commitment to implement every item. Validate each finding against real usage and measurements before changing behavior.

## Tracking conventions

Statuses:

- `Open` — not yet investigated.
- `Defined` — desired behavior and acceptance criteria are agreed.
- `In progress` — implementation has started.
- `Blocked` — awaiting a decision, dependency, or measurement.
- `Resolved` — implemented and verified.
- `Declined` — deliberately not pursuing; record the reason.

Priorities:

- `P1` — correctness, lifecycle, or resource-growth risk.
- `P2` — meaningful maintainability, testability, or user-facing improvement.
- `P3` — localized cleanup or documentation maintenance.

## Summary

The project is generally well-structured. Parsing, layout math, keyboard rules, and per-window thumbnail slots already have useful boundaries and focused tests. A broad rewrite is not recommended. The highest-value work is to bound live-frame delivery, improve subprocess execution and cancellation, and clarify capture/session lifecycle ownership.

| ID | Priority | Status | Finding |
|---|---|---|---|
| R-01 | P1 | Resolved | Bound the live-frame stream |
| R-02 | P1 | Resolved | Replace the synchronous subprocess runner |
| R-03 | P1 | Open | Clarify or strengthen capture timeouts |
| R-04 | P2 | Open | Split capture and overlay lifecycle responsibilities |
| R-05 | P2 | Open | Handle large workspace counts |
| R-06 | P2 | Open | Simplify debug-command startup |
| R-07 | P2 | Open | Consolidate duplicate snapshot concepts |
| R-08 | P2 | Open | Make interaction ownership explicit |
| R-09 | P3 | Open | Remove or implement unused state |
| R-10 | P3 | Open | Harden pure helpers and parsing |
| R-11 | P3 | Open | Refresh documentation |
| R-12 | P2 | Open | Add tests around lifecycle and infrastructure boundaries |

## Findings

### R-01 — Bound the live-frame stream

- **Priority:** P1
- **Status:** Resolved
- **Area:** Capture / performance / memory
- **Original evidence:** `CaptureService.liveThumbnailStream` created an `AsyncStream` with the default unbounded buffering policy. `LiveStreamOutput` coalesced frames before conversion, but converted `CGImage` values could still accumulate after `continuation.yield` if the main actor consumed them more slowly than producers emitted them.
- **Original impact:** Sustained animation across several windows could grow the post-conversion queue and memory use. The diagnostics `.dropped` branch was effectively unreachable under the unbounded buffering policy.
- **Decision:** Use per-window keyed buffering. Keep at most the newest pending frame for each window and count the replaced pending frame as dropped or coalesced.
- **Resolution notes:** `LatestByKeyBuffer` now backs the pull-based live-thumbnail stream. Repeated updates replace only the pending frame for the same window, while each distinct window retains one delivery slot and its relative delivery order. Pending-frame diagnostics are updated before the consumer resumes, and replacement keeps the reported backlog aligned with the buffer's bound. Stream cancellation finishes the buffer and rejects later frames.
- **Verification:** `make test` passes with focused coverage for per-window newest-frame behavior, cross-window retention, bounded pending count, shutdown rejection, stream cancellation, and replacement diagnostics. Runtime profiling under several animated windows remains optional validation rather than a correctness blocker.

### R-02 — Replace the synchronous subprocess runner

- **Priority:** P1
- **Status:** Resolved
- **Area:** AeroSpace integration / concurrency
- **Original evidence:** `AeroSpaceClient.run` drained stdout concurrently but read stderr only after process completion. A subprocess producing enough stderr could fill its pipe, block before closing stdout, and be misreported as a timeout. On timeout, the code called `terminate()` and threw without waiting for exit or explicitly completing both pipe drains. Snapshot queries used independent `Task.detached` operations, so they did not inherit structured cancellation or task priority.
- **Original impact:** Possible pipe deadlock, incomplete process cleanup, and work continuing after the requesting task was cancelled.
- **Decision:** Use a reusable asynchronous runner that concurrently drains stdout and stderr and does not return until the subprocess has exited and both drains finish. Timeout, cancellation, or excessive output sends `SIGTERM`, escalates to `SIGKILL` after a 300 ms grace period, and still awaits cleanup. Limit captured stdout to 4 MiB and stderr to 256 KiB. Classify `serverNotRunning` only from the verified full diagnostic `Can't connect to AeroSpace server. Is AeroSpace.app running?`; preserve other server-related failures as `commandFailed`.
- **Resolution notes:** `AsyncProcessRunner` now owns process launch, bounded dual-pipe reads, termination, escalation, and continuation completion. `AeroSpaceClient` maps runner failures into its domain errors, exposes an explicit oversized-output error, and performs independent queries with structured `async let`. Workspace and focus actions are async and no longer require a detached blocking task.
- **Verification:** `make test` passes 60 tests in 15 suites. Focused coverage exercises output larger than pipe capacity on both streams, nonzero exit diagnostics, timeout escalation for a process that ignores `SIGTERM`, cancellation cleanup, independent stdout/stderr limits, and precise server-unavailable classification.

### R-03 — Clarify or strengthen capture timeouts

- **Priority:** P1
- **Status:** Open
- **Area:** Capture / cancellation
- **Evidence:** `withTimeout` races an operation against `Task.sleep`, cancels the losing child, and returns from the task-group closure. Structured task groups still wait for their children to complete, so the 600 ms limit is strict only if the underlying ScreenCaptureKit operation promptly cooperates with cancellation.
- **Impact:** A stuck or cancellation-resistant capture can exceed the documented timeout and delay stream completion.
- **Candidate direction:** Either document the timeout as best-effort or use a capture primitive with explicit stop/cancellation semantics. Add a deterministic test with a cancellation-resistant operation.
- **Questions to define:**
  - Does `SCScreenshotManager.captureImage` reliably honor cancellation on supported macOS releases?
  - Is returning a placeholder on time while cleanup continues acceptable?
  - What resources must remain retained until a late capture finishes?
- **Resolution notes:** _Pending._

### R-04 — Split capture and overlay lifecycle responsibilities

- **Priority:** P2
- **Status:** Open
- **Area:** Architecture / maintainability
- **Evidence:** `CaptureService.swift` owns one-shot capture, wallpaper capture, live-stream startup, image conversion, coalescing, timeout logic, and stream cleanup. `OverlayController` owns panel presentation, loading state, capture lifecycle, layout harvests, diagnostics, actions, and animation. `OverlayController.shutdown()` does not cancel `harvestTask`.
- **Impact:** Lifecycle behavior is difficult to reason about and infrastructure components are difficult to test independently.
- **Candidate direction:** Consider boundaries such as `OneShotWindowCapturer`, `DesktopBackgroundCapturer`, `LiveThumbnailCoordinator`, and `LiveStreamOutput`. Model overlay lifecycle explicitly as `idle`, `loading`, `visible`, and `hiding`, with one session object owning related tasks.
- **Questions to define:**
  - Which split reduces complexity without creating protocol-heavy abstractions?
  - Should one overlay session own capture, diagnostics, and harvest cancellation together?
  - Which tasks must be cancelled during application shutdown?
- **Resolution notes:** _Pending._

### R-05 — Handle large workspace counts

- **Priority:** P2
- **Status:** Open
- **Area:** UI layout
- **Evidence:** `OverlayRootView` uses a fixed-column `LazyVGrid` without scrolling, while every workspace tile keeps a 16:10 aspect ratio. A sufficiently large workspace count can exceed the available display height.
- **Impact:** Tiles can be clipped or rendered outside the usable overlay on smaller displays or with many workspaces.
- **Candidate direction:** Add vertical scrolling, calculate tile geometry from available dimensions, or introduce a pure row/column layout helper based on workspace count and screen size.
- **Questions to define:**
  - What workspace counts and minimum display sizes must be supported?
  - Is scrolling acceptable for a Mission Control-style overlay?
  - Should keyboard navigation follow visual rows when the layout adapts?
- **Resolution notes:** _Pending._

### R-06 — Simplify debug-command startup

- **Priority:** P2
- **Status:** Open
- **Area:** Application entry point / CLI
- **Evidence:** `main.swift` duplicates semaphore and `Task.detached` bridging for `--dump` and `--dump-images`, uses `nonisolated(unsafe)` mutable exit codes, and force-unwraps UTF-8 conversion. A missing argument after `--dump-images` silently falls through to launching the menu-bar app.
- **Impact:** More unsafe concurrency than necessary and surprising command-line behavior.
- **Candidate direction:** Parse arguments into a small `DebugCommand` enum and run debug commands through one async bridge. Return a usage error for malformed flags and use `String(decoding:as:)` for encoded JSON.
- **Questions to define:**
  - Should unknown flags also produce usage errors?
  - Can the executable adopt a single async entry point without disrupting `NSApplication.run()`?
- **Resolution notes:** _Pending._

### R-07 — Consolidate duplicate snapshot concepts

- **Priority:** P2
- **Status:** Open
- **Area:** Models / view model
- **Evidence:** `AeroSpaceSnapshot` and `OverlaySnapshot` both own workspace arrays and repeat focused/all-window traversal. `OverlayViewModel.layouts` has a public setter while other published state is mutated through explicit methods.
- **Impact:** Duplicate model behavior and a wider mutation surface than necessary.
- **Candidate direction:** Let the overlay snapshot contain an `AeroSpaceSnapshot` plus permission state, or move common traversal onto a shared model. Make layouts `private(set)` and publish changes through a dedicated method.
- **Questions to define:**
  - Is `OverlaySnapshot` still useful as a distinct type once thumbnails and layouts are separate stores?
  - Should permission state belong to overlay content rather than the snapshot?
- **Resolution notes:** _Pending._

### R-08 — Make interaction ownership explicit

- **Priority:** P2
- **Status:** Open
- **Area:** SwiftUI interaction / accessibility
- **Evidence:** A workspace tile and the window thumbnails nested inside it attach separate `onTapGesture` handlers. The intended precedence is implicit, and gesture-only controls lack the semantics supplied by `Button`.
- **Impact:** Action ownership is harder to verify, and keyboard/VoiceOver behavior is weaker than it could be.
- **Candidate direction:** Use explicit buttons or deliberate gesture precedence so a thumbnail click emits exactly one focus intent while the surrounding tile emits one workspace intent. Add accessibility labels/actions.
- **Questions to define:**
  - Has nested gesture behavior been manually verified across supported macOS releases?
  - Should workspace tiles and thumbnails be reachable individually through accessibility navigation?
- **Resolution notes:** _Pending._

### R-09 — Remove or implement unused state

- **Priority:** P3
- **Status:** Open
- **Area:** General cleanup
- **Evidence:**
  - `FrameCacheStore.Entry.harvestedAt` is written but never read.
  - `ScreenRecordingPermission.request()` has no callers; launch warm-up currently triggers the permission flow.
  - Some diagnostics snapshot fields are collected but consumed only by tests, including status totals, total converted megapixels, and yielded-frame rate.
  - Capture size `320` and live rate `30` are repeated in `OverlayController`.
- **Impact:** Unclear intent and small amounts of unnecessary state or duplication.
- **Candidate direction:** Remove unused members, implement their intended policies, or document why the telemetry is deliberately retained. Centralize repeated capture constants.
- **Questions to define:**
  - Is cache expiry planned, making `harvestedAt` useful?
  - Are unused diagnostics fields intended for future exports or only historical experiments?
- **Resolution notes:** _Pending._

### R-10 — Harden pure helpers and parsing

- **Priority:** P3
- **Status:** Open
- **Area:** Parsing / layout math
- **Evidence:**
  - `naturalLess` has no deterministic fallback for names equivalent under numeric, case-insensitive comparison, such as `A`/`a` or `2`/`02`.
  - Focused-window parsing uses `try?`, while post-switch window IDs use `compactMap`; malformed output is silently treated as absent.
  - `LayoutMath.pickDisplay` can return an arbitrary display when total overlap is zero.
  - `FrameCacheStore.store` repeatedly calls `contains` on a generic collection instead of constructing a set once.
- **Impact:** Nondeterministic ordering and silent degradation in uncommon edge cases.
- **Candidate direction:** Add a stable lexical fallback, share a strict window-ID parser, reject zero-overlap layouts, and normalize ID collections to sets before filtering.
- **Questions to define:**
  - Should malformed focused-window output fail the entire snapshot or merely omit focus?
  - Are case-only or numeric-equivalent workspace names valid in AeroSpace configuration?
- **Resolution notes:** _Pending._

### R-11 — Refresh documentation

- **Priority:** P3
- **Status:** Open
- **Area:** README / specification / plan
- **Evidence:**
  - `PLAN.md` says live thumbnails use 640-pixel output; production uses 320.
  - `SPEC.md` still describes static thumbnails, a 250 ms timeout, a nonexistent monitor field, and menu/live thumbnails as future work.
  - `README.md` recommends `swift test`, while repository guidance says to use `make test` so the Xcode toolchain is pinned.
- **Impact:** Contributors can make decisions from outdated behavior and use the wrong build command.
- **Candidate direction:** Decide whether `SPEC.md` is historical or current. If historical, label it prominently and link to current behavior; otherwise update it. Correct the PLAN resolution and README test command.
- **Questions to define:**
  - Which document is authoritative for current behavior?
  - Should completed milestone notes remain immutable historical records?
- **Resolution notes:** _Pending._

### R-12 — Add tests around lifecycle and infrastructure boundaries

- **Priority:** P2
- **Status:** Open
- **Area:** Testing
- **Evidence:** Existing tests cover parsing, layout math, keyboard rules, placeholder rendering, frame coalescing, and diagnostic calculations well. The most important untested behavior sits behind concrete/private infrastructure.
- **Coverage added:** R-01 now covers keyed live-stream buffering, newest-frame semantics, replacement diagnostics, and cancellation.
- **Candidate direction:** Add focused coverage for the remaining boundaries:
  - Process stdout/stderr, nonzero exit, timeout, and cancellation behavior.
  - Cancellation-resistant timeout behavior.
  - Overlay session transitions and shutdown cancellation.
  - Missing or malformed debug-command arguments.
  - Large workspace counts and nested click intent.
  - Natural-sort ties and zero-display-overlap layouts.
- **Questions to define:**
  - Which dependencies need small protocols or closures for deterministic tests?
  - Which ScreenCaptureKit behavior requires integration tests rather than unit tests?
- **Resolution notes:** _Pending._

## Suggested order of investigation

1. R-03: continue establishing reliable resource and cancellation behavior after resolving R-01 and R-02.
2. R-12: add test seams alongside those infrastructure changes.
3. R-04: simplify lifecycle ownership using what was learned from the tests.
4. R-05 and R-08: address UI scalability and action semantics.
5. R-06, R-07, R-09, and R-10: perform localized simplifications.
6. R-11: update documentation after implementation decisions settle.

## Resolution log

Add dated entries here when findings change status.

| Date | ID | Change | Verification |
|---|---|---|---|
| 2026-08-14 | All | Initial review recorded | Static inspection; no source or generated files changed during review |
| 2026-08-14 | R-01 | Resolved with per-window keyed latest-frame delivery and replacement-aware diagnostics | `make test` — 53 tests in 13 suites passed |
| 2026-08-14 | R-02 | Resolved with a bounded asynchronous subprocess runner, structured queries, cancellation cleanup, and termination escalation | `make test` — 60 tests in 15 suites passed |
