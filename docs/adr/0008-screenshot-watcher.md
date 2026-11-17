# ADR-0008: Screenshot watcher

Status: Accepted; spike S-8 (TASK-011) pending (attribute timing, localised prefixes).

## Context
FR-002-04 specifies an FSEvents stream with file-level events, 0.3 s latency, non-recursive, with a 5 s listing fallback (`SSP-OS-001`). FR-002-06 recognises a screenshot by the `kMDItemIsScreenCapture` extended attribute or a localised filename prefix. FR-002-08 reconciles from a watermark (`screenshots.lastScanAt` in `meta`). FR-002-09 imports through the ingest pipeline with the file's own dates.

## Decision
- `FolderEventSource` port in Base; adapter `FSEventsFolderSource` in `App/Platform/` (FSEvents stream, filters direct children, ignores symlinks and subfolders) plus the polling variant of the same port, chosen by the adapter factory when stream creation fails.
- `Screenshots.ScreenshotWatcher` (actor) owns folder resolution (override, `com.apple.screencapture` `location`, Desktop), re-resolution every 30 s and on activation, the 0.5 s stability check, recognition, watermark reconcile, and handoff to `IngestActor`.
- Recognition is one function, `ScreenshotRecognizer`, holding the one `ScreenshotNamePrefixes` list and the attribute check; "Import recent screenshots" (FR-002-12) and live pickup both call it.
- Reading the attribute goes through the `FileSystemPort` (`extendedAttribute(named:)`).

## Alternatives rejected
- **`DispatchSource` vnode watching.** Directory vnode events report that something changed, not which file or whether it finished writing, and need one file descriptor per folder; we would rescan on every event.
- **Polling only.** Latency and wake-ups for a feature whose truth (P1 recall completeness) wants every screenshot; kept only as the fallback.
- **Spotlight query (`NSMetadataQuery`) for `kMDItemIsScreenCapture`.** Depends on Spotlight indexing, which can lag or be disabled; S-8 asks exactly whether the attribute is written at save time.

## Consequences
If S-8 finds the attribute lags, the prefix list becomes the primary signal and the 0.5 s stability check absorbs it, as FRD-002 Assumption 1 already anticipates; this is a one-file change.

## Reversibility
High.
