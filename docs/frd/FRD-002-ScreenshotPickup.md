# FRD-002 — Screenshot Pickup

**Status:** Draft · 2026-11-16 · Constitution: [TRUTHS.md](../TRUTHS.md) · PRD: [PRD.md](../PRD.md) (feature F2) · Errors: [FRD-000](FRD-000-ErrorSystem.md)
**Owns:** screenshot location resolution, watching, what counts as a screenshot, import timing and catch-up, backfill.
**Does not own:** storage, limits, image pipeline, dedupe key ([FRD-007](FRD-007-RetentionStorage.md), [FRD-001](FRD-001-Capture.md) FR-001-15); settings storage and UI ([FRD-008](FRD-008-OnboardingSettings.md)).

## Truth Test
- Serves: S2 — screenshots from the system folder join history automatically, so a screenshot is recallable like any clip.
- Supports: P1 — "anything you ... screenshotted ... in the past 30 days" is part of the primary truth; this is the only path that makes folder screenshots recallable, entirely locally.
- Violates: none. A3 ("not a screenshot tool") is respected: pickup only reads files the system already wrote. No capture, annotation, recording or OCR.
- Verdict: KEEP

## 1. Purpose
Notice screenshots that macOS saves to disk and add them to history as `screenshot` items without the user doing anything.

## 2. User Stories
- As a user, I take a screenshot with the system shortcut and it is in the Library moments later.
- As a user who changed the screenshot folder, pickup still works without telling Flotsam.
- As a user, deleting the file from the folder does not remove the history item, and deleting the item never deletes my file.
- As a user returning from a week of Flotsam being off, the screenshots I took meanwhile appear once.

## 3. Functional Requirements

**Where to watch**
- **FR-002-01** Location resolution, first match wins: (1) the user override `screenshots.folderOverride` if set (FRD-008); (2) the `location` value of the `com.apple.screencapture` preferences domain, with `~` expanded; (3) `~/Desktop`. A resolved folder must exist, be a directory and be listable; a symbolic link is resolved and the folder it points to is watched. A listing refused for lack of folder access does not make a folder invalid: that is FR-002-03 (`SSP-PRM-001`), not a fallback. If the system `location` (2) is invalid or unavailable (missing, unmounted volume), watch `~/Desktop` and raise `SSP-IO-001` once per change of state (macOS itself saves to the Desktop in that case). If an override (1) is invalid, pickup is paused and `SSP-IO-003` raised; it does not fall through to (2).
- **FR-002-02** Re-resolution. Location is re-resolved at launch, on `didBecomeActive`, and every 30 s (the 60th tick of the shared poll timer, ADR-0004; the watcher has no timer of its own; the 30 s holds while capture is Paused, when the shared timer slows to 5 s, FR-001-19). When the resolved folder differs, the watcher is torn down and rebuilt on the new folder and a reconcile scan (FR-002-08) runs on it.
- **FR-002-03** Folder access. A first read of Desktop, Documents or Downloads triggers the system's folder-access prompt. A permission failure on listing the folder raises `SSP-PRM-001`, leaves pickup idle, and retries every 30 s and on `didBecomeActive`; the warning clears on the first successful listing, or when the folder resolves to paused (an invalid override, `SSP-IO-003`), since nothing is listed then.

**How to watch**
- **FR-002-04** Mechanism. An FSEvents stream with file-level events and 0.3 s latency on the resolved folder, non-recursive: only direct children are considered; subfolders and symbolic links are ignored. If the stream cannot be created or is reported invalid, fall back to listing the folder every 5 s and raise `SSP-OS-001`; leaving the fallback (stream creation succeeds on a later re-resolution) clears it, as does the folder resolving to paused (`SSP-IO-003`), since nothing is polled then.
- **FR-002-05** Pickup enabled flag. `screenshots.enabled` (default true, FRD-008). Off → no watcher, no timer, no folder access. Turning it on sets the scan watermark to now (FR-002-08): screenshots taken while it was off are not imported unless the user runs "Import recent screenshots" (FR-002-12). Capture modes apply too (FRD-007 FR-007-12): while capture is Paused or Curated, pickup imports nothing but still advances the watermark, so screenshots taken during the pause are not imported on resume.

**What counts as a screenshot**
- **FR-002-06** A direct child file qualifies when all hold: (a) name does not start with `.` (macOS writes a hidden temporary name, then renames; the rename event is the creation); (b) extension, case-insensitive, is one of `png`, `jpg`, `jpeg`, `tiff`, `tif`, `heic`; (c) it is recognised as a screenshot: the extended attribute `com.apple.metadata:kMDItemIsScreenCapture` is true, or, when that attribute is absent, the file name begins with the `name` value of `com.apple.screencapture` if set, or with one of the prefixes in the single constant list `ScreenshotNamePrefixes` = "Screenshot", "Screen Shot", and the localised screenshot name macOS ships for every system language (the `Screenshot` entry of the system screenshot app's catalogue; 2026-11-17 spike: every language's file-name format starts with it). An attribute that is present but false rejects the file, whatever its name. Name comparison ignores the invisible soft hyphen (U+00AD) and right-to-left mark (U+200F) the system catalogue puts in some names, and treats composed and decomposed accents as equal. Recordings (`.mov`), PDFs, GIFs and any other file are ignored with no log entry. The same recognition applies in an override folder.
- **FR-002-07** Stability. Before import a candidate must have an unchanged size and modification date across two checks 0.5 s apart and be readable. If not stable within 5 s it is skipped as `SSP-IO-002` and put on an in-memory retry list tried again at subsequent reconcile scans: up to 3 retries after the first skip (4 tries in all), then dropped (Import recent screenshots can still bring it in).

**When to import**
- **FR-002-08** Watermark and reconcile scan. The timestamp `screenshots.lastScanAt` is stored in the database `meta` table (FRD-007). A reconcile scan lists the folder and imports qualifying files whose creation (birth) date is later than `lastScanAt` minus 5 s, then sets `lastScanAt` to the scan's start time. With no `lastScanAt` yet (a new library), the scan imports nothing and only sets it; older screenshots arrive through Import recent screenshots (FR-002-12), which onboarding offers. It runs at launch, after any watcher rebuild, on wake from sleep, and on `didBecomeActive`. This is what catches screenshots taken while Flotsam was not running, without re-importing a file whose item the user deleted (older than the watermark). The watermark also follows live pickup, so that this holds for a screenshot imported while Flotsam was running: when a live file is imported (or recognised as not importable), and on each 30 s tick while the folder is being watched, `lastScanAt` moves to that moment, but never past the creation date of a file that is still unfinished (queued, unstable, failed, or a hidden temporary name macOS may still rename into a screenshot) for 60 s after that file was created, and never past 5 s after the creation date of the file just imported (so the 5 s margin cannot select it again). Live file events are still judged against the last scan's time, not this later one. Each scan ends with one log line carrying its outcome (succeeded or failed) and how many files it queued, and never a file name.
- **FR-002-09** Import. An import reads the file bytes once and passes them to the ingest pipeline (FRD-007 FR-007-05) as kind `screenshot`: the item owns a stored copy; the original file is never moved, renamed, modified or deleted by Flotsam. `createdAt` and `lastCopiedAt` are set to the file's creation (birth) date, not the import time (its modification date on a volume that records no birth date), so Recent ordering matches when the screenshot was taken. The source app is the catalogue label `ui.source.screenshot` with bundle identifier `com.apple.screencaptureui`. The original path is stored for "Reveal in Finder" (FRD-003) and used only for that.
- **FR-002-10** Dedupe. The FR-001-15 rule applies unchanged (class `image`, raw bytes): a screenshot whose bytes match an existing item bumps that item and creates nothing. Re-detection of the same file (events fire several times per save) is idempotent for the same reason.
- **FR-002-11** Independence. Deleting the source file never removes the item. Deleting the item never touches the source file. A screenshot that never touched a folder (system "Save to Clipboard") is not a pickup event; it arrives through capture as an `image` item (FRD-001).
- **FR-002-12** Backfill. "Import recent screenshots" imports qualifying files regardless of watermark, limited to creation dates within the current retention window (FRD-007; at most 30 days when retention is longer) and at most the 500 newest, oldest first. It is offered once in onboarding (checkbox, default on) and is always available in Settings, including while pickup is off or the capture mode is not Active: it is the user's explicit request, so neither FR-002-05 gate applies to it. Existing items are untouched (dedupe). For MVP a 500-file backfill may take on the order of 2 minutes (about 125 s is accepted); it has no latency budget, since the FR-002-14 p95 covers live pickup only. It runs in the background, never blocks the UI, and must not starve live pickup: a live screenshot goes ahead of every queued backfill file. Pressing it shows "Importing…" at once, and when the run ends one HUD: "Imported {n}" with the real count (0 for an empty folder or files already in the library), or, when the run could not happen, the failure's own message and never a count: the library failed to open, the chosen folder is missing (SSP-IO-003), the folder cannot be read (SSP-PRM-001), or every file failed to store. A press made before the library has opened waits for it and then behaves the same way. Two presses never run two passes: a press during a run joins it. A press that coincides with live pickup (the reconcile scan on `didBecomeActive` queues the same new files) counts every file its own scan finds new to the library: it joins the imports queued or in flight when its scan returns and waits for them, and it also counts a file live pickup imported after the press began, so its "Imported {n}" includes the items those imports create as well as its own; a file live pickup imported before the press began is already in the library, is not counted and is not ingested again by the press, so each file is ingested once. Pressing again after a press still runs and creates no duplicates.
- **FR-002-13** Limits and pacing. A file over the image ceiling (FRD-007 FR-007-06) is skipped with `SSP-LIM-001`. A file that is not a decodable image is skipped with `SSP-VAL-001`. A burst is processed serially with at most 2 imports in flight; a stuck file never blocks others.
- **FR-002-14** Performance. For a file that is already final, the screenshot is a queryable Library item at p95 ≤ 2.0 s (0.3 s event latency + 0.5 s stability check + persist; the thumbnail may follow). With pickup enabled and no screenshots, idle cost is under 0.1 % CPU (event-driven; the 30 s re-resolution runs on the shared poll tick and adds no wake-ups of its own, ADR-0004).
- **FR-002-15** Privacy. Logs carry outcome, byte size and counts only; file names, paths and the screenshot folder path are never logged or shown in Notices (FR-000-10). The Settings pane may show the folder path to the user locally.
- **FR-002-16** Link safety. A file is read only if it is a regular file (not a symbolic link, whatever the link points at) that is a direct child of the folder being watched, both as it is named and as it resolves. A link, any file that resolves outside that folder, and any file reached through a subfolder or a link to a folder (even one that leads back to the watched folder) is never opened. The scan drops it silently like any other non-qualifying entry (FR-002-06). The check is repeated at import, and the read itself refuses to follow a link: a file that is swapped for a link at any moment up to the read is not read, the import is skipped with `SSP-VAL-001`, and it is not retried. One rule serves both checks (`ScreenshotPathGuard`). The watched folder itself may be a symbolic link (a relocated Desktop, an override folder) or be spelled with `..`: it is resolved first, then listed, and files inside it are judged by the rules above.

## 4. Data Requirements
- Settings read: `screenshots.enabled`, `screenshots.folderOverride` (FRD-008 registry).
- Persisted: `meta.screenshots.lastScanAt` (FRD-007). Item fields added by this FRD: none beyond `kind = screenshot` and `originalPath` (FRD-007 schema).
- In memory: current resolved folder, retry list (path, attempts).

## 5. Business Rules
- Recall only; Flotsam never creates, edits or deletes screenshot files.
- Pickup never crosses folders: one watched folder at a time.
- A screenshot deleted from history is not resurrected by launch or wake scans.
- The recognition test is identical for the system folder, Desktop fallback and an override.

## 6. Error States (codes in FRD-000 §7)
| Situation | Code | Behaviour |
|---|---|---|
| Folder access denied | SSP-PRM-001 | idle; retry every 30 s and on activation |
| System folder invalid, using Desktop | SSP-IO-001 | watch Desktop; Notice once |
| File unstable or unreadable | SSP-IO-002 | skip; retry list (3 retries after the first skip) |
| Override folder missing | SSP-IO-003 | paused until it returns |
| Not a decodable image, or swapped for a link before import (FR-002-16) | SSP-VAL-001 | skip |
| File over ceiling | SSP-LIM-001 | skip; Notice |
| FSEvents unavailable | SSP-OS-001 | 5 s directory polling |
| Storage failure on import | STO-* via the pipeline | item not stored; Notice |

## 7. Acceptance Criteria
- **AC-002-01** (FR-002-01) Given `defaults write com.apple.screencapture location ~/Pictures/Shots` (folder exists), when a screenshot is taken, then it is imported from that folder; given the folder is then removed, then Desktop is watched and `SSP-IO-001` appears once; given an override is set to a missing folder, then pickup is paused with `SSP-IO-003` and Desktop is not used.
- **AC-002-02** (FR-002-02) Given the system location changes while Flotsam runs, then the new folder is watched within 30 s with no restart.
- **AC-002-03** (FR-002-03) Given folder access is denied for the watched folder, then `SSP-PRM-001` is raised, and within 30 s of access being granted a screenshot taken afterward is imported.
- **AC-002-04** (FR-002-04) Given the FSEvents stream is forced to fail in a test, then `SSP-OS-001` is raised and a new screenshot is still imported within 5.5 s.
- **AC-002-05** (FR-002-06) Given the watched folder receives: a system screenshot (png), a screenshot saved as jpg, a `.mov` recording, a PDF, a hidden temp file, a screenshot in a subfolder, and an unrelated `holiday.png` with no screen-capture attribute and a non-screenshot name, then only the first two are imported.
- **AC-002-06** (FR-002-07) Given a file still growing for 3 s then final, then it is imported once after it stops changing; given a file that grows for over 5 s, then it is skipped (`SSP-IO-002`) and imported by the next reconcile scan.
- **AC-002-07** (FR-002-08) Given Flotsam is quit, 3 screenshots are taken, and Flotsam is launched, then exactly 3 items appear; given one is deleted from history and Flotsam is relaunched, then it does not reappear. The same holds when the 3 screenshots are taken while Flotsam is running, one is deleted, and Flotsam is quit and relaunched before any scan has run.
- **AC-002-08** (FR-002-09,11) Given a screenshot is imported, then its item date equals the file's creation date, the item has a stored copy, deleting the original file leaves the item and its preview intact, and deleting the item leaves the original file on disk.
- **AC-002-09** (FR-002-05) Given pickup is turned off, screenshots are taken, and pickup is turned on, then none of them is imported until "Import recent screenshots" is run, which imports them once.
- **AC-002-10** (FR-002-12) Given 700 qualifying screenshots within 30 days, when "Import recent screenshots" runs, then the 500 newest are imported; running it again creates no duplicates.
- **AC-002-11** (FR-002-14) Given 20 screenshots taken in 10 s, then all are imported, at most 2 imports are in flight at once, and p95 time to queryable per file meets FR-002-14.
- **AC-002-12** (FR-002-15) Given the screenshot file name contains a unique marker, when logs and the diagnostics report are searched, then zero matches.
- **AC-002-13** (FR-002-16) Given a symbolic link named like a screenshot in the watched folder, pointing at a file inside the folder, outside it, or via `../`, then it is not listed and nothing behind it is read; given a listed file that is replaced by such a link before import, then the import is skipped with `SSP-VAL-001` and no item is created.
- **AC-002-14** (FR-002-16) Given a watched folder that is itself a symbolic link to a folder holding screenshots, when it is scanned, then its qualifying files are listed (and links inside it are still dropped per AC-002-13).
- **AC-002-15** (FR-002-12) Given the library failed to open, the chosen screenshot folder is missing or refused, or every file fails to store, when "Import recent screenshots" is pressed (including a press made before the library finished opening), then the HUD shows that failure's message, never "Imported 0".

## 8. UI Inventory
| Element | Type | Where | Behavior |
|---|---|---|---|
| Pick up screenshots | toggle | Settings › General (FRD-008) | sets `screenshots.enabled`; default on |
| Screenshot folder | read-only path label + status | Settings › General | shows resolved folder and state (Watching, Using Desktop, Needs access, Paused) |
| Choose folder... | button | Settings › General | opens folder picker; sets override |
| Use system setting | button | Settings › General | clears override; shown only when an override exists |
| Import Recent Screenshots | button with count result | Settings › General | runs FR-002-12; shows "Importing…", then "Imported {n}" in a HUD, or the failure message when the run could not happen |
| Onboarding step: screenshots | step with checkbox | Onboarding (FRD-008) | explains folder access; "Import screenshots from the last 30 days" checked by default |
| Notices | menu entries | menu bar | SSP-PRM-001, SSP-IO-001, SSP-IO-003, SSP-LIM-001, SSP-OS-001 |
| Screenshot row and filter | list row, sidebar filter | Library (FRD-003) | uses kind `screenshot`; action "Reveal in Finder" |

## 9. Assumptions to verify (architecture spikes)
1. **Verified 2026-11-17 (macOS 26.7):** `com.apple.metadata:kMDItemIsScreenCapture` (a binary plist boolean) is on the file as soon as `screencapture` writes it, before Spotlight indexing. The prefix fallback stays for files without the attribute.
2. **Resolved 2026-11-17 (macOS 26.7):** the prefix list is taken from the system screenshot app's own catalogue for all 41 shipped localisations (34 distinct names), not only the nine languages first listed. Gaps cost only a missed auto-import, and Import recent screenshots has the same recognition rule.
3. macOS saving to Desktop when `location` is invalid.
4. Backfill default (checked) is a product choice made here to serve P1's 30 days; it can be flipped to unchecked without touching other FRs.

## 10. Out of Scope
Capturing, annotating, recording or OCR of screenshots (A3). Screen recordings (CUT, see CUT.md). Watching more than one folder. Importing non-screenshot images from folders. Removing or moving original files. Screenshots taken by third-party tools unless they set the screen-capture attribute or use a recognised name.
