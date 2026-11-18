# ADR-0011: Testing seams

Status: Accepted (2026-11-16).

## Context
`FlotsamCore` must be testable without UI, permissions or real time. The risky behaviours (poll gates, retention, paste timing, trigger matching, screenshot recognition) all depend on the pasteboard, the clock, the filesystem or a key event stream.

## Decision
System access is a protocol (a port) declared in `Base/Ports` and implemented either in the app target (`App/Platform/`) or as a test double in `FlotsamTestSupport`-style files inside each test target (no shared test-support target until 3 modules need the same double; Rule: no premature abstraction).

In the skeleton (used by real code today):
| Port | Isolation | Real adapter | Used by |
|---|---|---|---|
| `WallClock` (`now()`, `sleep(for:)`) | Sendable | system | everything with a timer or timestamp |
| `FileSystemPort` (subset: exists, attributes, list, move, remove, extended attribute, permissions) | Sendable | `FileManager` | Storage blobs, Screenshots |
| `PasteboardPort` (`changeCount`, `readSnapshot`, `write`) | `@MainActor` | `NSPasteboard.general` | Capture, Paste |
| `KeyValueStore` (get/set/observe) | Sendable | `UserDefaults` | `SettingsStore` |
| `ScreenCapturePreferences` (`location`, `name`) | Sendable | CFPreferences, `com.apple.screencapture` | Screenshots (FRD-002) |
| `ClipboardCapture.TimerScheduler` (closure: interval, tolerance, fire, returns a cancel) | `@MainActor` | `Timer` on `RunLoop.main`, `.common` | Capture poll timer (TASK-430); a closure inside `FlotsamCapture`, not a `Base/Ports` protocol, because only Capture schedules the timer |

Declared when the owning FRD is built, not before: `FrontmostAppProvider`, `KeyEventPoster`, `KeyEventSource`, `HotkeyRegistrar`, `FolderEventSource`, `PermissionProbe`.

Log sink seam (TASK-432, FRD-000 FR-000-11): the classes that now log `LogEvent`s take `sink: any LogSink = OSLogSink()` as a trailing initializer parameter, the same seam `TriggerExpander` and `FlotsamDatabase` already had, so a test can capture the lines instead of reading the system log. Added to `PasteService`, `ShortcutRegistry` and `TriggerEngine`; `FlotsamDatabase` passes its existing `logSink` into the open attempt. `PermissionTransitionLogger` (FlotsamBase) wraps `PermissionProbe` and the sink and is called by the App target at launch and on activation. `BudgetOutcome.evictedBytes` and an internal `deleteItemsWhileEligible` return the byte counts the retention line needs; the existing `deleteWhileEligible` is unchanged for callers.

Tooling and targets:
- Swift Testing (`import Testing`), run with `swift test` in `Packages/FlotsamCore`; one test target per library target.
- Storage tests use real SQLite files in a temp directory (never mocks for the database).
- Coverage targets: at least 90% lines on Base, Storage, Payload; at least 80% on the other package targets. App-target code is covered by UI and manual tests listed per FRD. These are my targets, not an FRD requirement; they are stated here so a ticket can fail against them.
- Time-based behaviour is tested with a manual `WallClock` double advanced by the test.

## Alternatives rejected
- **Mock the database.** Pragmas, transactions and FTS behaviour are the risk; only a real file tests them.
- **A shared `FlotsamTestSupport` target now.** One user today.

## Reversibility
High.
