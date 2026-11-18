# ADR-0004: Concurrency model

Status: Accepted (2026-11-16).

## Context
Swift 6 strict concurrency. Hard timing facts: pasteboard poll every 0.5 s (FR-001-01); main thread never hashes, converts images or touches the database (FR-001-17, FR-007-02); tap callback ≤ 1 ms p99 and never on the main thread (FR-005-11, -21); retention batch holds the writer ≤ 50 ms (FR-007-09); one image in flight (FR-007-07).

## Decision
| Domain | Isolation | Rule |
|---|---|---|
| UI, panels, status item, Settings, onboarding, HUD | `@MainActor` | View state types are `@MainActor`; no business logic in views (Rule 9 locality). |
| Pasteboard poll | `@MainActor` timer (`.common`, 0.5 s, 0.1 s tolerance), the only timer for recurring work (see "Recurring work" below) | Compares `changeCount` only. On change: the gates and the byte read for the chosen representations happen on the main actor (a copy of bytes, no decoding), then an immutable `Sendable` `CapturedPayload` crosses to the ingest actor. Hashing, conversion, thumbnails and database work never run on main. |
| Ingest | `actor IngestActor` in Storage | The single serial entry for FR-007-05 (capture, screenshot import, Shelf drop). Serial order is what makes two identical payloads create one item. |
| Database | GRDB `DatabasePool` (ADR-0002) | One writer, concurrent readers. Storage exposes only `async` functions returning `Result`; no synchronous read exists, so a main-thread read cannot be written. |
| Image pipeline and thumbnails | Child of the ingest actor, one image at a time; thumbnails on a low-priority `Task` | 64 MB LRU thumbnail cache is an actor (`ThumbnailCache`), emptied when the last panel closes (S5); ingest writes thumbnails to disk only. |
| Retention, reconcile, integrity | `actor RetentionScheduler` | Timer from the injected clock (30 s after launch, hourly, on wake); batches of 500. |
| Screenshot watcher | `actor ScreenshotWatcher` | FSEvents callbacks arrive on a private dispatch queue and are bridged into an `AsyncStream` consumed by the actor. Folder re-resolution runs on every 60th poll tick (30 s) through `PollTick`; it owns no timer. |
| Settings | `final class SettingsStore: Sendable` over `UserDefaults` (thread-safe) | Reads are synchronous and callable from anywhere; changes are published as an `AsyncStream` of the new `Sendable` value. Threads that cannot call it (the tap thread) hold an immutable snapshot (ADR-0007). |
| Paste back | `@MainActor PasteService` | Hides the panel, awaits non-visibility, `await clock.sleep(40ms)`, checks the frontmost app, posts ⌘V through the `KeyEventPoster` port. |
| Trigger tap | One dedicated thread with its own `CFRunLoop` | The matcher is confined to that thread (not `Sendable`, never shared). Expansion (FR-005-14) runs in a `Task` off the tap thread. |
| Hotkeys | Carbon event handler on the main thread | Dispatches to `@MainActor` command handlers. |

Recurring work (truth S5, at most 2.5 wake-ups/s idle; the poll alone is about 2.0/s, and a separate 5 s watchdog plus 30 s re-resolve timer measured 2.71 to 2.90/s):
- The pasteboard poll timer is the one source of idle wake-ups. Other periodic work registers with `PollTick` (`FlotsamBase`) as `every(seconds)`, which runs it on every Nth tick (`seconds / 0.5`) and returns a cancel closure. The poll timer calls `PollTick.fire()` once per tick; the work it runs only spawns a `Task` onto its own isolation domain, so the main actor does no more than a counter check. Registered today: the tap watchdog (every 10th tick, 5 s, FR-005-19) and the folder re-resolve (every 60th tick, 30 s, FR-002-02). Granularity is one tick, so a 5 s or 30 s period holds to within the poll's own 0.1 s tolerance.
- A new recurring job uses `PollTick`; a new timer needs an amendment here. `PollTick` owns the cadence: it reports `cadence`, and the one timer, owned by `ClipboardCapture`, is rescheduled to follow it; a second timer is never added. While capture is Paused (FR-001-19) the pasteboard poll is skipped and the cadence slows to the coarsest interval the remaining registered work needs, the greatest common divisor of their periods: 5 s with the watchdog and the re-resolve, 30 s with only the re-resolve, and no timer at all when nothing is registered. Time is counted in base 0.5 s ticks and each slow firing advances that many, and when the cadence changes the work due before the first firing at the new cadence runs at once, and the interval already elapsed at the old cadence counts toward it (the timer is re-created, so its first firing is a full new interval away), so a pause, a resume, or work joining or leaving never stretches a period and the work may run earlier than its period, never later. Back-to-back changes at one instant do not credit the same interval twice. Resume restores 0.5 s, reads the `changeCount` baseline at the moment the mode changes (on the main thread, inside the setting change itself, so no check can run between the change and the baseline) and runs one immediate check, so nothing copied while Paused is captured. Recurring work with a period under 5 s would force the Paused cadence below 5 s and needs an amendment here.
- Exceptions, each with its cost and why it is not on the tick:
  - Retention sweep: `RetentionScheduler` sleeps 30 s once, then 1 h between sweeps, and wakes on wake-from-sleep. About 0.0003 wake-ups/s. Too coarse to share a 0.5 s tick.
  - Reconcile sweep: `ReconcileScheduler` sleeps 15 s once, then 7 days. Effectively zero idle cost.
  - Fallback folder poll: `PollingFolderSource`, 5 s, runs only after the FSEvents stream fails (FR-002-04). 0.2 wake-ups/s while degraded, none otherwise.
  - Transient waits: the 40 ms to 500 ms paste, clipboard-restore, expander and screenshot stability waits, and the UI dismiss delays. They run only while one user action is in flight and never recur while idle.

Rules:
- Values crossing isolation are `Sendable` value types; `@unchecked Sendable` and `nonisolated(unsafe)` are allowed only for (a) the tap-thread context object, (b) the immutable trigger snapshot holder and (c) the `UserDefaults` stored in `UserDefaultsStore` (Apple documents `UserDefaults` as thread-safe), each with a comment naming the invariant, and are listed in `docs/ARCHITECTURE.md`. A new one needs an ADR amendment.
- No `DispatchQueue.main.sync`, no blocking wait on a Task, no `Thread.sleep` outside the tap thread's run loop.
- Cancellation: every long-running actor loop checks `Task.isCancelled` between units of work; quitting cancels the ingest actor after the in-flight transaction.
- Timers and delays use the injected `Clock` (ADR-0011); `PollTick` is driven by the poll timer and counts firings at the cadence it reports; its only use of time is a monotonic uptime read (injectable) to tell changes at the same instant from changes a tick or more apart, tests call `fire()` directly so the 40 ms, 250 ms, 300 ms and 500 ms windows are testable without sleeping.

## Open item (not decided)
Reading a 100 MiB image's bytes on the main actor is a memory copy that can hitch the UI. If the `capture.persist` signpost shows it, the read moves to a background context; whether `NSPasteboard.general` data reads are safe off the main thread is unverified and belongs to spike S-4's remit. Until measured, the main-actor read stands.

## Alternatives rejected
- **Global actor for everything off-main.** One queue would let a 5 s retention scan delay a paste. Separate actors give separate failure and latency domains.
- **Combine / callbacks.** Doubles the concurrency vocabulary; `AsyncStream` covers every fan-out we have.

## Reversibility
High. Isolation is per type; changing one actor does not move the others.
