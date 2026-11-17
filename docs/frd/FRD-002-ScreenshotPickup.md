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
- **FR-002-01** Location resolution, first match wins: (1) the user override `screenshots.folderOverride` if set (FRD-008); (2) the `location` value of the `com.apple.screencapture` preferences domain, with `~` expanded; (3) `~/Desktop`. A resolved folder must exist, be a directory and be listable. If the system `location` (2) is invalid or unavailable (missing, unmounted volume), watch `~/Desktop` and raise `SSP-IO-001` once per change of state (macOS itself saves to the Desktop in that case). If an override (1) is invalid, pickup is paused and `SSP-IO-003` raised; it does not fall through to (2).
- **FR-002-02** Re-resolution. Location is re-resolved at launch, on `didBecomeActive`, and every 30 s. When the resolved folder differs, the watcher is torn down and rebuilt on the new folder and a reconcile scan (FR-002-08) runs on it.
- **FR-002-03** Folder access. A first read of Desktop, Documents or Downloads triggers the system's folder-access prompt. A permission failure on listing the folder raises `SSP-PRM-001`, leaves pickup idle, and retries every 30 s and on `didBecomeActive`; the warning clears on the first successful listing.

**How to watch**
- **FR-002-04** Mechanism. An FSEvents stream with file-level events and 0.3 s latency on the resolved folder, non-recursive: only direct children are considered; subfolders and symbolic links are ignored. If the stream cannot be created or is reported invalid, fall back to listing the folder every 5 s and raise `SSP-OS-001`; leaving the fallback (stream creation succeeds on a later re-resolution) clears it.
- **FR-002-05** Pickup enabled flag. `screenshots.enabled` (default true, FRD-008). Off → no watcher, no timer, no folder access. Turning it on sets the scan watermark to now (FR-002-08): screenshots taken while it was off are not imported unless the user runs "Import recent screenshots" (FR-002-12). Capture modes apply too (FRD-007 FR-007-12): while capture is Paused or Curated, pickup imports nothing but still advances the watermark, so screenshots taken during the pause are not imported on resume.

**What counts as a screenshot**
- **FR-002-06** A direct child file qualifies when all hold: (a) name does not start with `.` (macOS writes a hidden temporary name, then renames; the rename event is the creation); (b) extension, case-insensitive, is one of `png`, `jpg`, `jpeg`, `tiff`, `tif`, `heic`; (c) it is recognised as a screenshot: the extended attribute `com.apple.metadata:kMDItemIsScreenCapture` is true, or, when that attribute is absent, the file name begins with one of the prefixes in the single constant list `ScreenshotNamePrefixes` = the `name` value of `com.apple.screencapture` if set, "Screenshot", "Screen Shot", and the localised equivalents Apple ships for French, German, Spanish, Dutch, Italian, Japanese, Chinese (Simplified and Traditional) and Korean. Recordings (`.mov`), PDFs, GIFs and any other file are ignored with no log entry. The same recognition applies in an override folder.
- **FR-002-07** Stability. Before import a candidate must have an unchanged size and modification date across two checks 0.5 s apart and be readable. If not stable within 5 s it is skipped as `SSP-IO-002` and put on an in-memory retry list tried again at the next reconcile scan, at most 3 attempts.

**When to import**
- **FR-002-08** Watermark and reconcile scan. The timestamp `screenshots.lastScanAt` is stored in the database `meta` table (FRD-007). A reconcile scan lists the folder and imports qualifying files whose creation (birth) date is later than `lastScanAt` minus 5 s, then sets `lastScanAt` to the scan's start time. It runs at launch, after any watcher rebuild, on wake from sleep, and on `didBecomeActive`. This is what catches screenshots taken while Flotsam was not running, without re-importing a file whose item the user deleted (older than the watermark).
- **FR-002-09** Import. An import reads the file bytes once and passes them to the ingest pipeline (FRD-007 FR-007-05) as kind `screenshot`: the item owns a stored copy; the original file is never moved, renamed, modified or deleted by Flotsam. `createdAt` and `lastCopiedAt` are set to the file's creation date, not the import time, so Recent ordering matches when the screenshot was taken. The source app is the catalogue label `source.screenshot` with bundle identifier `com.apple.screencaptureui`. The original path is stored for "Reveal in Finder" (FRD-003) and used only for that.
- **FR-002-10** Dedupe. The FR-001-15 rule applies unchanged (class `image`, raw bytes): a screenshot whose bytes match an existing item bumps that item and creates nothing. Re-detection of the same file (events fire several times per save) is idempotent for the same reason.
- **FR-002-11** Independence. Deleting the source file never removes the item. Deleting the item never touches the source file. A screenshot that never touched a folder (system "Save to Clipboard") is not a pickup event; it arrives through capture as an `image` item (FRD-001).
- **FR-002-12** Backfill. "Import recent screenshots" imports qualifying files regardless of watermark, limited to creation dates within the current retention window (FRD-007; at most 30 days when retention is longer) and at most the 500 newest, oldest first. It is offered once in onboarding (checkbox, default on) and is always available in Settings. Existing items are untouched (dedupe).
- **FR-002-13** Limits and pacing. A file over the image ceiling (FRD-007 FR-007-06) is skipped with `SSP-LIM-001`. A file that is not a decodable image is skipped with `SSP-VAL-001`. A burst is processed serially with at most 2 imports in flight; a stuck file never blocks others.
- **FR-002-14** Performance. For a file that is already final, the screenshot is a queryable Library item at p95 ≤ 2.0 s (0.3 s event latency + 0.5 s stability check + persist; the thumbnail may follow). With pickup enabled and no screenshots, idle cost is under 0.1 % CPU (event-driven; no timers except the 30 s re-resolution).
- **FR-002-15** Privacy. Logs carry outcome and byte size only; file names, paths and the screenshot folder path are never logged or shown in Notices (FR-000-10). The Settings pane may show the folder path to the user locally.

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
| File unstable or unreadable | SSP-IO-002 | skip; retry list (3 attempts) |
| Override folder missing | SSP-IO-003 | paused until it returns |
| Not a decodable image | SSP-VAL-001 | skip |
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
- **AC-002-07** (FR-002-08) Given Flotsam is quit, 3 screenshots are taken, and Flotsam is launched, then exactly 3 items appear; given one is deleted from history and Flotsam is relaunched, then it does not reappear.
- **AC-002-08** (FR-002-09,11) Given a screenshot is imported, then its item date equals the file's creation date, the item has a stored copy, deleting the original file leaves the item and its preview intact, and deleting the item leaves the original file on disk.
- **AC-002-09** (FR-002-05) Given pickup is turned off, screenshots are taken, and pickup is turned on, then none of them is imported until "Import recent screenshots" is run, which imports them once.
- **AC-002-10** (FR-002-12) Given 700 qualifying screenshots within 30 days, when "Import recent screenshots" runs, then the 500 newest are imported; running it again creates no duplicates.
- **AC-002-11** (FR-002-14) Given 20 screenshots taken in 10 s, then all are imported, at most 2 imports are in flight at once, and p95 time to queryable per file meets FR-002-14.
- **AC-002-12** (FR-002-15) Given the screenshot file name contains a unique marker, when logs and the diagnostics report are searched, then zero matches.

## 8. UI Inventory
| Element | Type | Where | Behavior |
|---|---|---|---|
| Pick up screenshots | toggle | Settings › General (FRD-008) | sets `screenshots.enabled`; default on |
| Screenshot folder | read-only path label + status | Settings › General | shows resolved folder and state (Watching, Using Desktop, Needs access, Paused) |
| Choose folder... | button | Settings › General | opens folder picker; sets override |
| Use system setting | button | Settings › General | clears override; shown only when an override exists |
| Import recent screenshots | button with count result | Settings › General | runs FR-002-12; shows "Imported {n}" in a HUD |
| Onboarding step: screenshots | step with checkbox | Onboarding (FRD-008) | explains folder access; "Import screenshots from the last 30 days" checked by default |
| Notices | menu entries | menu bar | SSP-PRM-001, SSP-IO-001, SSP-IO-003, SSP-LIM-001, SSP-OS-001 |
| Screenshot row and filter | list row, sidebar filter | Library (FRD-003) | uses kind `screenshot`; action "Reveal in Finder" |

## 9. Assumptions to verify (architecture spikes)
1. `com.apple.metadata:kMDItemIsScreenCapture` is written by the system at save time (not only after Spotlight indexes). If it lags, the filename-prefix fallback is the primary signal and the 0.5 s stability check absorbs it.
2. The localised prefix list is complete enough; verify against macOS language settings on a test machine. Gaps cost only a missed auto-import, and Import recent screenshots has the same recognition rule.
3. macOS saving to Desktop when `location` is invalid.
4. Backfill default (checked) is a product choice made here to serve P1's 30 days; it can be flipped to unchecked without touching other FRs.

## 10. Out of Scope
Capturing, annotating, recording or OCR of screenshots (A3). Screen recordings (CUT, see CUT.md). Watching more than one folder. Importing non-screenshot images from folders. Removing or moving original files. Screenshots taken by third-party tools unless they set the screen-capture attribute or use a recognised name.
