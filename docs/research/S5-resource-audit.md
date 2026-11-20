# S5 resource audit (TASK-373)

Truth S5, "Invisible on the machine": idle (no panel open, 10,000 items, 10 minutes) at most 0.2 % of one core,
2.5 wake-ups/s and 60 MB physical footprint; panel open at most 150 MB physical footprint. Every FRD was re-tested against it.

## How it was measured

- Harness: a scratch executable linking FlotsamCore (not in the repo), 10,000-item library (1,000 images, 2,000
  thumbnails on disk), release build, run under a watchdog (4 GB RSS cap, time cap), one run per scenario, machine
  shared with other builds (numbers are noisy; a quiet-machine re-run of the poll rows is ticketed).
- Counters: `proc_pid_rusage` (`RUSAGE_INFO_V4`): CPU time, package-idle + interrupt wake-ups, resident size,
  physical footprint, sampled over a ~127 s window after a settle period. Needs no sudo.
- **powermetrics was not used.** It needs sudo; `proc_pid_rusage` gives the same per-process wake-up count without it.
- The pasteboard poll, FSEvents watcher, event tap, Shelf and Library UI do not exist in code yet. Their rows are
  **spec-only** verdicts, backed for the poll by a prototype timer process (PollProto) measured the same way.

## Measured

| Scenario (10k items) | CPU | Wake-ups/s | RSS | Footprint |
|---|---|---|---|---|
| Idle, 45 s settle, before | 0.000 % | 0.02 | 14.4 MB | 6.9 MB |
| Idle, 45 s settle, after | 0.000 % | 0.02 | 10.1 MB | 6.5 MB |
| Idle, no settle (launch sweeps at 15 s / 30 s), before | 0.894 % | 0.05 | 7.5 MB | 6.8 MB |
| Idle, no settle, after | 0.404 % | 0.05 | 13.8 MB | 6.5 MB |
| After 200 live image ingests, idle, before | 0.468 % | 0.04 | **63.7 MB** | 18.3 MB |
| After 200 live image ingests (disk-only thumbnails) and a `releaseMemory()` call, idle, after; the two changes are not isolated | 0.728 %* | 0.27* | **14.5 MB** | 9.1 MB |
| Panel browsed 1,000 images, then closed, before | 0.422 % | 0.05 | 60.7 MB | 10.6 MB (47.4 MB while open) |
| Same, with `releaseMemory()`, after | 0.405 % | 0.07 | 59.6 MB | 10.7 MB (47.4 MB while open) |

\* Thumbnail writes of the last ingests were still finishing inside the window; the launch sweeps sit in the
no-settle rows. Idle with sweeps finished is 0.000 %.

Poll prototype (45 s windows, except combo rows at 120 s; machine busy during combo):

| Variant | CPU | Wake-ups/s |
|---|---|---|
| No timer (process floor) | 0.001 % | 0.11 |
| `Timer` 0.5 s, tolerance 0.1 s (FR-001-01 as specified) | 0.015 % | 2.07 |
| `Timer` 0.5 s, tolerance 0.25 s | 0.016 % | 2.04 |
| `DispatchSourceTimer` 0.5 s, leeway 0.1 s | 0.011 % | 2.02 |
| `Timer` 1 s, tolerance 0.25 s | 0.009 % | 1.07 |
| Poll + 5 s tap watchdog + 30 s folder re-resolve, with slack | 0.017 % | 2.90 |
| Same, no slack | 0.018 % | 2.71 |

Reading:
- **The one real win is ingest.** Warming thumbnails through the memory LRU filled it with data nobody was looking
  at: 200 image copies left 63.7 MB resident, over the 60 MB line. Ingest now writes thumbnail files only; the same
  run, with `releaseMemory()` also called, idles at 14.5 MB. The two were not measured separately: since
  `releaseMemory()` showed no effect of its own in the panel scenario (below), the drop is attributed to the ingest
  change by inference, not isolated.
- The poll alone costs about 2.0 wake-ups/s of the 2.5/s budget and 0.015 % CPU. Timer tolerance and leeway do not
  reduce it; a 1 s poll would halve it but breaks the 0.6 s detection latency of FR-001-20.
- Adding the 5 s tap watchdog and the 30 s re-resolve as separate timers measured 2.71 to 2.90/s: over budget.
  Fixed by TASK-381: both now run on counters of the one poll tick (every 10th and every 60th). The folded
  configuration was not re-measured with `proc_pid_rusage` in that task (no app launch); the expected figure is the
  poll's own ~2.0/s plus no extra timers, to be confirmed by the next idle measurement run.
- `releaseMemory()` showed **no measurable footprint or RSS change** after the panel scenario: footprint falls from
  47.4 MB open to about 10.6 MB with or without it, and RSS stays near 60 MB either way. The reason the footprint
  falls without it was not confirmed. It stays because S5 requires an idle app to hold no thumbnail cache and the
  call is cheap, but its benefit is unproven; the post-panel RSS (about 60 MB, at the budget line) is ticketed.
- Launch sweeps (retention at 15 s, reconcile at 30 s) cost about 1 s of CPU in total on 10k items. The harness
  `sweeps` mode that isolates them was not run.

## Dropped experiments

- `malloc_zone_pressure_relief` inside `releaseMemory()`: made it worse (live: RSS 53.9 MB, footprint 16.3 MB
  against 14.5 / 9.1 MB without it; panel: RSS 69.8 MB, footprint 36.9 MB against 59.6 / 10.7 MB). Removed.
- An alpha-only (1 byte per pixel) scan in `ImagePipeline.hasTransparency`: does not compile, because `CGContext`
  cannot take a nil colour space for an alpha-only context in Swift. It would only have cut a transient 4 B/px peak
  at ingest, not idle. Reverted; not pursued.

## Verdicts (FRD-000..008)

M = measured here, S = spec-only (code does not exist yet or was not isolated).

| FRD | Requirement | Verdict | Basis |
|---|---|---|---|
| 000 | FR-000-13 in-memory error ring buffer (100 entries) | KEEP | S, tiny and bounded |
| 000 | Log sink writes | KEEP | S, only on events, no periodic flush |
| 001 | FR-001-01 0.5 s poll, `changeCount` only | KEEP | M (prototype): 2.0 wake-ups/s, 0.015 % |
| 001 | FR-001-19 Paused keeps the timer running | CHANGE | S: stop the poll while Paused and slow the shared timer to 5 s (TASK-382, done) |
| 001 | FR-001-20 / AC-001-01 / AC-001-16 budgets | CHANGE | edited to the S5 numbers in this commit; the single wake-up source is in place (TASK-381) |
| 002 | FR-002-02 30 s folder re-resolve | CHANGE | M (prototype): folded into the poll tick (TASK-381, done; wake-ups not re-measured) |
| 002 | FR-002-04 FSEvents 0.3 s latency | KEEP | S, event-driven, no idle cost |
| 002 | FR-002-04 5 s polling fallback | KEEP | S, only after the stream fails; rare |
| 002 | FR-002-14 pickup CPU | KEEP | S |
| 003 | FR-003-05 50 newest rows held in memory | CHANGE | S: released when the last panel closes (stated in FRD-003's in-memory data list, not in FR-003-05's text; wiring TASK-383) |
| 003 | FR-003-13 64 MB thumbnail LRU | CHANGE | M: emptied on panel close (target state, TASK-383); ingest no longer fills it |
| 004 | Actions are single transactions, no timers | KEEP | S |
| 005 | FR-005-11 typed-word buffer, tap on its own thread | KEEP | S, event-driven; verify when built |
| 005 | FR-005-19 5 s tap watchdog | CHANGE | M (prototype): fold into the poll tick or make event-driven (ticket) |
| 005 | FR-005-16 clipboard copy held about 300 ms | KEEP | S, transient |
| 006 | FR-006-07 Shelf shares the thumbnail cache | KEEP | S |
| 006 | FR-006-17 / AC-006-18 idle Shelf has no timers | KEEP | S, already stated |
| 007 | FR-007-07 ingest thumbnails | CHANGE | M: file only, never the memory cache (edited and coded here) |
| 007 | FR-007-09 hourly retention sweep, launch and wake sweeps | KEEP | M: about 1 s CPU at launch; not periodic-heavy |
| 007 | FR-007-13 `quick_check` at launch | KEEP | S, once per launch |
| 007 | BlobStore fsync on every write | KEEP, low-priority ticket | S, no measured cost; only ingest-time |
| 007 | SQLite cache_size, mmap, wal_autocheckpoint left at defaults | KEEP, low-priority ticket | S, no measured cost |
| 007 | `ThumbnailCache.touch` is O(n) | KEEP, low-priority ticket | S, n is bounded by 64 MB of 20 KB thumbnails |
| 008 | Permission re-read every 2 s only while Settings is visible | KEEP | S, not idle |
| 008 | Settings change stream, `UserDefaults` | KEEP | S, event-driven |

## Landed in this commit

- Code: `FlotsamDatabase.releaseMemory()` (empties the thumbnail LRU, releases SQLite page caches);
  ingest writes thumbnail files only (`writeThumbnails`).
- Spec, same commit: FRD-001 FR-001-20, AC-001-01, AC-001-16; FRD-003 FR-003-13 and the in-memory list;
  FRD-007 FR-007-07; ADR-0004 image-pipeline row.
- Wired by TASK-383: `PanelResidency` (FlotsamBase) calls `releaseMemory()` when the last of Library and Shelf is gone, and each panel drops its rows (Library: loaded rows and preview content; Shelf: cards and texts) when it hides. Real-panel measurements (RSS after 1,000 images browsed and closed, 10 minutes idle at 10k items) are still owed; the residency cause is unconfirmed (candidates: malloc/ImageIO retained pages that RSS counts but footprint does not, SwiftUI image caches in the hosting views; neither measured).
