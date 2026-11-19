# ADR-0008: Screenshot watcher

Status: Accepted; spike S-8 done 2026-11-17 on macOS 26.7: the attribute is written at save time, and the prefix list comes from the system screenshot app's catalogue for every shipped language (FRD-002 §9).

## Context
FR-002-04 specifies an FSEvents stream with file-level events, 0.3 s latency, non-recursive, with a 5 s listing fallback (`SSP-OS-001`). FR-002-06 recognises a screenshot by the `kMDItemIsScreenCapture` extended attribute or a localised filename prefix. FR-002-08 reconciles from a watermark (`screenshots.lastScanAt` in `meta`). FR-002-09 imports through the ingest pipeline with the file's own dates.

## Decision
- `FolderEventSource` port in Base; adapter `FSEventsFolderSource` in `App/Platform/` (FSEvents stream, filters direct children, ignores symlinks and subfolders) plus the polling variant of the same port, chosen by the adapter factory when stream creation fails.
- `Screenshots.ScreenshotWatcher` (actor) owns folder resolution (override, `com.apple.screencapture` `location`, Desktop), re-resolution every 30 s (on the shared poll tick, ADR-0004) and on activation, the 0.5 s stability check, recognition, watermark reconcile, and handoff to `IngestActor`.
- Recognition is one function, `ScreenshotRecognizer`, holding the one `ScreenshotNamePrefixes` list and the attribute check; "Import recent screenshots" (FR-002-12) and live pickup both call it.
- Reading the attribute goes through the `FileSystemPort` (`extendedAttribute(named:)`); birth date and entry kind (regular, directory, link) come from its `fileInfo(at:)`.
- The system `location` and `name` preferences come from a `ScreenCapturePreferences` port in Base, read fresh on every resolution; its CFPreferences adapter is Foundation-only, so it sits beside `LocalFileSystem` in Base.
- `ScreenshotWatcher.stop()` ends a watcher for good: it cuts new work, lets imports already accepted finish (their watermark writes land), then deactivates; every later event, tick, wake, activation, settings change, start or press does nothing. The app never calls it (the watcher lives for the process), so product behaviour is unchanged; it exists so a test that relaunches the watcher can retire the old one instead of leaking a live watcher that races the new one (TASK-510).

## Alternatives rejected
- **`DispatchSource` vnode watching.** Directory vnode events report that something changed, not which file or whether it finished writing, and need one file descriptor per folder; we would rescan on every event.
- **Polling only.** Latency and wake-ups for a feature whose truth (P1 recall completeness) wants every screenshot; kept only as the fallback.
- **Spotlight query (`NSMetadataQuery`) for `kMDItemIsScreenCapture`.** Depends on Spotlight indexing, which can lag or be disabled; S-8 asks exactly whether the attribute is written at save time.

## Consequences
If S-8 finds the attribute lags, the prefix list becomes the primary signal and the 0.5 s stability check absorbs it, as FRD-002 Assumption 1 already anticipates; this is a one-file change.

## Reversibility
High.
