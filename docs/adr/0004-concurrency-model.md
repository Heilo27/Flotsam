# ADR-0004: Concurrency model

Status: Accepted (2026-11-16).

## Context
Swift 6 strict concurrency. Hard timing facts: pasteboard poll every 0.5 s (FR-001-01); main thread never hashes, converts images or touches the database (FR-001-17, FR-007-02); tap callback ≤ 1 ms p99 and never on the main thread (FR-005-11, -21); retention batch holds the writer ≤ 50 ms (FR-007-09); one image in flight (FR-007-07).

## Decision
| Domain | Isolation | Rule |
|---|---|---|
| UI, panels, status item, Settings, onboarding, HUD | `@MainActor` | View state types are `@MainActor`; no business logic in views (Rule 9 locality). |
| Pasteboard poll | `@MainActor` timer (`.common`, 0.5 s, 0.1 s tolerance) | Compares `changeCount` only. On change: the gates and the byte read for the chosen representations happen on the main actor (a copy of bytes, no decoding), then an immutable `Sendable` `CapturedPayload` crosses to the ingest actor. Hashing, conversion, thumbnails and database work never run on main. |
| Ingest | `actor IngestActor` in Storage | The single serial entry for FR-007-05 (capture, screenshot import, Shelf drop). Serial order is what makes two identical payloads create one item. |
| Database | GRDB `DatabasePool` (ADR-0002) | One writer, concurrent readers. Storage exposes only `async` functions returning `Result`; no synchronous read exists, so a main-thread read cannot be written. |
| Image pipeline and thumbnails | Child of the ingest actor, one image at a time; thumbnails on a low-priority `Task` | 64 MB LRU thumbnail cache is an actor (`ThumbnailCache`). |
| Retention, reconcile, integrity | `actor RetentionScheduler` | Timer from the injected clock (30 s after launch, hourly, on wake); batches of 500. |
| Screenshot watcher | `actor ScreenshotWatcher` | FSEvents callbacks arrive on a private dispatch queue and are bridged into an `AsyncStream` consumed by the actor. Folder re-resolution every 30 s. |
| Settings | `final class SettingsStore: Sendable` over `UserDefaults` (thread-safe) | Reads are synchronous and callable from anywhere; changes are published as an `AsyncStream` of the new `Sendable` value. Threads that cannot call it (the tap thread) hold an immutable snapshot (ADR-0007). |
| Paste back | `@MainActor PasteService` | Hides the panel, awaits non-visibility, `await clock.sleep(40ms)`, checks the frontmost app, posts ⌘V through the `KeyEventPoster` port. |
| Trigger tap | One dedicated thread with its own `CFRunLoop` | The matcher is confined to that thread (not `Sendable`, never shared). Expansion (FR-005-14) runs in a `Task` off the tap thread. |
| Hotkeys | Carbon event handler on the main thread | Dispatches to `@MainActor` command handlers. |

Rules:
- Values crossing isolation are `Sendable` value types; `@unchecked Sendable` and `nonisolated(unsafe)` are allowed only for (a) the tap-thread context object, (b) the immutable trigger snapshot holder and (c) the `UserDefaults` stored in `UserDefaultsStore` (Apple documents `UserDefaults` as thread-safe), each with a comment naming the invariant, and are listed in `docs/ARCHITECTURE.md`. A new one needs an ADR amendment.
- No `DispatchQueue.main.sync`, no blocking wait on a Task, no `Thread.sleep` outside the tap thread's run loop.
- Cancellation: every long-running actor loop checks `Task.isCancelled` between units of work; quitting cancels the ingest actor after the in-flight transaction.
- Timers and delays use the injected `Clock` (ADR-0011) so the 40 ms, 250 ms, 300 ms and 500 ms windows are testable without sleeping.

## Open item (not decided)
Reading a 100 MiB image's bytes on the main actor is a memory copy that can hitch the UI. If the `capture.persist` signpost shows it, the read moves to a background context; whether `NSPasteboard.general` data reads are safe off the main thread is unverified and belongs to spike S-4's remit. Until measured, the main-actor read stands.

## Alternatives rejected
- **Global actor for everything off-main.** One queue would let a 5 s retention scan delay a paste. Separate actors give separate failure and latency domains.
- **Combine / callbacks.** Doubles the concurrency vocabulary; `AsyncStream` covers every fan-out we have.

## Reversibility
High. Isolation is per type; changing one actor does not move the others.
