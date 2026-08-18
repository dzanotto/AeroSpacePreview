# Refactoring and Cleanup Review

Reviewed: 2026-08-14
Scope: production sources, tests, Swift package/build configuration, and project documentation
Review method: static, read-only inspection; tests were not run during the review to avoid updating generated build artifacts

## Purpose

This document records potential refactors, simplifications, and cleanups for later investigation. It is a non-authoritative work tracker, not technical documentation or a commitment to implement every item. The source is authoritative; current design explanations are consolidated in [ARCHITECTURE.md](ARCHITECTURE.md). Validate each finding against real usage and measurements before changing behavior.

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
| R-03 | P1 | Resolved | Clarify or strengthen capture timeouts |
| R-04 | P2 | Open | Split capture and overlay lifecycle responsibilities |
| R-05 | P2 | Open | Handle large workspace counts |
| R-06 | P2 | Open | Simplify debug-command startup |
| R-07 | P2 | Open | Consolidate duplicate snapshot concepts |
| R-08 | P2 | Open | Make interaction ownership explicit |
| R-09 | P3 | Open | Remove or implement unused state |
| R-10 | P3 | Open | Harden pure helpers and parsing |
| R-11 | P3 | Resolved | Refresh documentation |
| R-12 | P2 | Resolved | Add tests around lifecycle and infrastructure boundaries |

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
- **Status:** Resolved
- **Area:** Capture / cancellation
- **Original evidence:** `withTimeout` races an operation against `Task.sleep` and cancels the losing child. Structured task groups still wait for their children to complete, so the 600 ms limit is strict only if the underlying ScreenCaptureKit operation promptly cooperates with cancellation.
- **Original impact:** A stuck or cancellation-resistant capture can exceed the documented timeout and delay stream completion.
- **Findings:** [`SCScreenshotManager.captureImage`](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage%28contentfilter%3Aconfiguration%3Acompletionhandler%3A%29) is exposed as an Objective-C completion-handler API, available since macOS 14.0, with no cancellation token, returned operation handle, or stop method. Its Swift `async throws` overload is compiler-imported by suspending on a continuation, as described by [SE-0297](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0297-concurrency-objc.md); that translation does not add a cancellation handler. Swift task cancellation is cooperative, and a task group cannot leave its scope until cancelled children complete, as specified by [SE-0304](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md). Apple publishes no promise that cancelling the awaiting Swift task aborts or promptly completes an in-progress screenshot. Normal quick completion after cancellation must not be interpreted as cancellation support.
- **Decision:** Treat the 600 ms limit as a best-effort timeout, not a hard deadline. Preserve structured task ownership so the capture task and any objects it retains remain alive until ScreenCaptureKit calls the completion handler. Do not detach late captures merely to return a placeholder at exactly 600 ms; the overlay can already present placeholders without waiting for captures. If a future requirement needs a strict return deadline or prompt physical capture shutdown, use a separately owned late-completion lifecycle or a primitive such as `SCStream` with explicit `stopCapture()` semantics.
- **Resolution notes:** The timeout contract is now documented next to `perWindowTimeout`. Across all supported macOS versions, code must assume `SCScreenshotManager.captureImage` is non-cancellable because the public API provides no supported cancellation mechanism. A synthetic cancellation-resistant test would only reconfirm Swift task-group semantics and cannot establish undocumented ScreenCaptureKit behavior across OS releases, so no such unit test is required for this documentation-only resolution.
- **Verification:** Static inspection of the macOS SDK declaration, Apple API documentation, SE-0297, SE-0304, and the local timeout/capture lifecycle. No runtime behavior changed.

### R-04 — Split capture and overlay lifecycle responsibilities

- **Priority:** P2
- **Status:** Open
- **Area:** Architecture / maintainability
- **Evidence:** `CaptureService.swift` owns one-shot capture, wallpaper capture, live-stream startup, image conversion, coalescing, timeout logic, and stream cleanup. `OverlayController` still coordinates panel presentation, AeroSpace state, capture consumption, layout caches, diagnostics, actions, and animation. R-12 introduced `OverlayLifetime`, which now models `idle`, `loading`, `visible`, and `hiding`, rejects stale session callbacks, owns per-session tasks, and cancels post-switch harvests at shutdown.
- **Impact:** Capture infrastructure remains difficult to test independently, and the controller's summon flow still spans several responsibilities. The highest-risk lifecycle transitions and cleanup rules now have a deterministic boundary and focused coverage.
- **Candidate direction:** Consider boundaries such as `OneShotWindowCapturer`, `DesktopBackgroundCapturer`, `LiveThumbnailCoordinator`, and `LiveStreamOutput`. Use the existing `OverlayLifetime` session boundary rather than introducing a second lifecycle abstraction.
- **Questions to define:**
  - Which split reduces complexity without creating protocol-heavy abstractions?
  - Should more of the capture-and-publish workflow move behind the session boundary, or should the lifetime remain a narrow state/task owner?
  - Should in-flight post-action AeroSpace commands also be explicitly cancelled during application shutdown?
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
- **Status:** Resolved
- **Area:** README / specification / plan
- **Original evidence:**
  - `PLAN.md` says live thumbnails use 640-pixel output; production uses 320.
  - `SPEC.md` still describes static thumbnails, a 250 ms timeout, a nonexistent monitor field, and menu/live thumbnails as future work.
  - `README.md` recommends `swift test`, while repository guidance says to use `make test` so the Xcode toolchain is pinned.
- **Original impact:** Contributors could make decisions from outdated behavior and use the wrong build command.
- **Decision:** Source code is the only authority. `README.md` is the advanced-user entry point, and `ARCHITECTURE.md` is the single current technical/design document. Completed specifications and milestone records remain available through Git history rather than the working tree.
- **Resolution notes:** Rewrote the README around installation, permissions, operation, diagnostics, and current limitations; added a code-aligned architecture document; removed `SPEC.md` and `PLAN.md`; narrowed `AGENTS.md` to contributor guidance; and replaced milestone/document references in source comments and the Makefile with self-contained rationale.
- **Verification:** Repository-wide reference scan; `make test` — 61 tests in 15 suites passed.

### R-12 — Add tests around lifecycle and infrastructure boundaries

- **Priority:** P2
- **Status:** Resolved
- **Area:** Testing
- **Original evidence:** Tests covered parsing, layout math, keyboard rules, placeholder rendering, frame coalescing, and diagnostic calculations well, while important lifecycle and infrastructure behavior sat behind concrete/private components.
- **Decision:** Add small concrete seams only where deterministic infrastructure tests require them. Keep platform behavior that cannot be established by a synthetic unit test documented as an integration constraint. Leave product-policy cases attached to their owning findings rather than resolving them implicitly through a testing change.
- **Resolution notes:** R-01 covers keyed live-stream buffering, newest-frame semantics, replacement diagnostics, and cancellation. R-02 covers dual-pipe output, nonzero exit, timeout escalation, cancellation cleanup, output limits, and error classification. R-03 documents why a synthetic cancellation-resistant test cannot establish ScreenCaptureKit behavior. `OverlayLifetime` now provides an identity-based state and task-ownership boundary for `idle`, `loading`, `visible`, and `hiding`; it cancels capture, live-stream, diagnostics, and harvest work at the appropriate lifecycle boundary and rejects late work after shutdown.
- **Deferred coverage:** Debug argument parsing, large-workspace layout, nested click intent, natural-sort ties, and zero-display-overlap policy remain with R-06, R-05, R-08, and R-10 respectively, where their expected behavior can be defined before tests lock it in.
- **Verification:** `make test` — 90 tests in 18 suites passed. Focused lifecycle coverage exercises valid and stale transitions, shutdown from every active phase, idempotent resource cleanup, rejected late installation, harvest replacement, and harvest shutdown cancellation.

## Suggested order of investigation

1. R-04: simplify capture and controller responsibilities using the lifecycle seam.
2. R-05 and R-08: address UI scalability and action semantics.
3. R-06, R-07, R-09, and R-10: perform localized simplifications.

## Resolution log

Add dated entries here when findings change status.

| Date | ID | Change | Verification |
|---|---|---|---|
| 2026-08-14 | All | Initial review recorded | Static inspection; no source or generated files changed during review |
| 2026-08-14 | R-01 | Resolved with per-window keyed latest-frame delivery and replacement-aware diagnostics | `make test` — 53 tests in 13 suites passed |
| 2026-08-14 | R-02 | Resolved with a bounded asynchronous subprocess runner, structured queries, cancellation cleanup, and termination escalation | `make test` — 60 tests in 15 suites passed |
| 2026-08-14 | R-03 | Resolved by documenting `SCScreenshotManager.captureImage` as non-cancellable and the 600 ms limit as best-effort while retaining structured cleanup | SDK and API-contract inspection; source documentation updated; no runtime behavior changed |
| 2026-08-18 | R-11 | Consolidated current documentation, made code authoritative, and removed the obsolete specification and milestone plan | Repository-wide reference scan; `make test` — 61 tests in 15 suites passed |
| 2026-08-18 | R-12 | Added an identity-based overlay lifecycle/task owner, stale-callback guards, shutdown-safe harvest ownership, and focused lifecycle tests | `make test` — 90 tests in 18 suites passed |
