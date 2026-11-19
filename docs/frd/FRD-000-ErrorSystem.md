# FRD-000 — Error System

**Status:** Draft · 2026-11-16 · Constitution: [TRUTHS.md](../TRUTHS.md) · PRD: [PRD.md](../PRD.md) (feature F0)
**Owns:** error type, code namespace, the single user-facing string catalogue, logging contract, diagnostics report.
**Read first by:** every other FRD. Feature FRDs reference codes from §7; they never define ad-hoc strings.

## Truth Test
- Serves: P1 — "none of it ever leaves the Mac": logs and diagnostics are specified so clip content can never reach them, and nothing is transmitted.
- Supports: S1 — a single typed catalogue keeps permission and limit failures explainable instead of silent.
- Violates: none (A4 respected: no crash-reporting service, no telemetry; diagnostics are user-initiated and copy-to-clipboard only).
- Verdict: KEEP

## 1. Purpose
Every failure in Flotsam has a typed, code-numbered error; every user-visible message comes from one catalogue; every log line is
safe to paste into a public GitHub issue. This FRD is the contract the other eight FRDs obey.

## 2. User Stories
- As a user, when something fails I learn what happened and what to do next, in plain words, never a stack trace.
- As a user, I can copy a diagnostics report into a bug report and be certain it contains none of my clips.
- As a maintainer, I can find every message the app can show in one file and every error path by code.

## 3. Functional Requirements

**Error type**
- **FR-000-01** Every fallible operation returns `Result<T, FlotsamError>`. `FlotsamError` is a `Sendable` value type with: `code` (an `ErrorCode` enum case, §FR-000-03), `severity` (derived from the code, not caller-supplied), `internalMessage` (static string literal, English, no interpolation of user data), `context` (`[LogKey: LogSafeValue]`), `underlying` (optional `UnderlyingErrorInfo` = domain string + integer code only; never `localizedDescription`, which can embed file paths).
- **FR-000-02** No error crosses a module boundary as a thrown `Error`, `NSError` or `String`. Force-try, force-unwrap and `fatalError` on external data (pasteboard, files, database rows, defaults) are forbidden; `fatalError` is allowed only for the two Fatal codes in FR-000-04 and for programmer-error invariants that cannot be reached from external input.
- **FR-000-03** Code format: `<MOD>-<CAT>-<NNN>`. Modules: `SYS` core, `CAP` capture (FRD-001), `SSP` screenshot pickup (FRD-002), `LIB` library (FRD-003), `ORG` organize (FRD-004), `TRG` shortcuts and triggers (FRD-005), `SHF` shelf (FRD-006), `STO` storage and retention (FRD-007), `SET` settings, onboarding, permissions (FRD-008). Categories: `PRM` permission, `IO` file or disk, `DB` database, `VAL` validation of user input or external data, `LIM` size or count limit, `OS` system API failure, `POL` expected skip by policy (always Info), `DAT` data-state inconsistency, `INT` internal. Numbers are three digits, per module+category, never reused or renumbered; a retired code stays in §7 marked `retired`, is removed from the code enumeration so it cannot be raised, and has no catalogue text.

**Severity and recovery**
- **FR-000-04** Four severities, fixed per code in §7:
  - **Fatal** — Flotsam cannot run safely. Show a modal alert with the user message, a "Reveal Data Folder" button and a "Quit" button, then terminate. If the data folder does not exist (`STO-IO-002`), "Reveal Data Folder" reveals its nearest existing ancestor and never creates the folder. Closed list: `STO-IO-002`, `STO-DB-003`. No other code may be Fatal.
  - **Error** — the user's action or a background save failed. Propagate to the caller, surface per FR-000-08, never crash.
  - **Warning** — the app is degraded but working (permission off, limit hit, fallback active). Log at notice, continue, surface per FR-000-08.
  - **Info** — an expected, policy-driven or benign skip (for example a transient pasteboard item). Log only; never shown to the user and never recorded in the ring buffer (FR-000-13).

**Catalogue and strings**
- **FR-000-05** One catalogue: the Xcode String Catalog `Localizable.xcstrings`. Every user-facing string in the app (errors and normal UI) is a catalogue key; no user-facing string literal appears in a view or model. Error messages use keys `error.<code>` (for example `error.SET-PRM-001`). Source language English; plural and count variations use catalogue variations, not string concatenation. Every string that puts a count next to a noun carries `one` and `other` plural variations, so a count of 1 reads "1 item" (never "1 items"): `ui.library.footerItems`, `ui.row.bundleCount`, `ui.organize.confirmDelete`, `ui.organize.confirmDeleteTag`, `ui.settings.clearCount`, `ui.settings.clearDone`, `ui.settings.confirmShorten` and `ui.settings.confirmBudget`. Counts with no noun ("Imported %lld", "%lld selected", "%lld of 2,000") and `error.CAP-LIM-003` (always above 500) need no plural. A test sweeps the catalogue so a new count-plus-noun string without plural variations fails it, and the raw-catalogue fallback resolves plurals the same way so no format specifier is ever shown. Each code's argument kinds (a count fills `%lld`, text fills `%@`) must match its message's format specifiers; a consistency check fails the tests on a mismatch. Showing a message never crashes: if the arguments do not fit the message, the user sees the SYS-INT-001 text instead.
- **FR-000-06** Message style: one or two sentences, ≤ 140 characters, states what happened then what to do, no jargon, no blame, no error code inline. A message may interpolate only: counts, byte sizes, durations, permission names, and the display name of an app. It may never interpolate clip text, URLs, file or folder names, notes, tags, trigger strings or search queries. The 140-character limit holds whatever is interpolated: a long app name is cut with "…" so the whole message fits. A negative count, size or duration shows as 0, and zero shows in digits ("0 bytes"), never as a word.
- **FR-000-07** The §7 table is the specification of the catalogue. A unit test enumerates every `ErrorCode` and fails if any code lacks a catalogue key (Warning/Error/Fatal), has a duplicate raw value, has a catalogue key with no code, or has a message over 140 characters.

**Surfaces**
- **FR-000-08** Surfacing rule. (a) User-initiated action fails (paste, hotkey, edit, drop, expansion): show a HUD — a small non-activating floating label, top-centre of the screen with the pointer, 2.5 s, no focus change. (b) Background failure (capture, screenshot pickup, retention): add a dot badge to the menu-bar icon and append to the Notices list (menu bar › Notices, newest 10 kept in memory, cleared on "Dismiss all" or quit). (c) Fatal: modal alert (FR-000-04). (d) Input rejected and shown inline by the view that took it (ORG-VAL, ORG-LIM, TRG-VAL codes marked "inline" in §7): logged and recorded in the ring buffer like any Error, never a HUD or Notice, and outside the throttle. Throttle: the same code surfaces at most once per 60 s and at most 3 HUDs per minute overall; throttled occurrences are still logged. A surfacing exactly 60 s old has expired, so the same code may surface again at T+60. A surfacing time later than the current time (the clock was set back) also counts as expired, for both the per-code timer and the HUD window, so one extra notice may appear but errors are never hidden until the clock catches up. When the owner of a long-lived condition clears that code's Notices because the condition ended (FR-001-18, FRD-002 FR-002-03/04, FRD-005 FR-005-10 and FR-005-19), the code's 60 s throttle is cleared with them: the same condition returning inside the 60 s is a new occurrence and surfaces at once. "Dismiss all" does not clear the throttle. (e) The capture cue (FRD-001 FR-001-30) is not an error surface: it confirms a successful capture, is not a HUD or a Notice, is neither throttled nor counted in the 3 HUDs per minute, and is never logged.

**Logging**
- **FR-000-09** Logging uses `os.Logger`, subsystem = the app bundle identifier, one category per module (`core`, `capture`, `screenshots`, `library`, `organize`, `triggers`, `shelf`, `storage`, `settings`). Level mapping: Info → `.info`, Warning → `.notice`, Error → `.error`, Fatal → `.fault`. Verbose traces use `.debug` and are wrapped in `#if DEBUG` so they are compiled out of release builds. `print`, `NSLog` and `dump` are forbidden in app sources (lint-enforced).
- **FR-000-10** Content never appears in any log, error context, signpost, Notice or diagnostics report. Forbidden: clip text, URLs, colours, phone numbers, emails, file and folder names or paths of user items, screenshot file names, bundle names, notes, tag names, trigger strings, search queries, typed-key buffers. Every dynamic value interpolated into a log string carries an explicit privacy qualifier: `.private` by default; `.public` only for the allowlist — error code, severity, item kind, counts, byte sizes, durations, booleans, enum raw values, system-declared pasteboard type identifiers (UTIs), OS and app versions. Source-app bundle identifiers, and any pasteboard type identifier that is not system-declared (an app's own type, a `dyn.` identifier), are `.private`; the log context types accept only a validated bundle identifier and a classified type identifier, never a free string.
- **FR-000-11** Mandatory instrumented callsites (each logs code or outcome only): pasteboard change processed (kind, byte size, outcome: stored / deduped / skipped + `POL` code); screenshot import outcome; screenshot reconcile-scan outcome; paste-back start and outcome (a copy-only paste logs as `paste.copy`, not `paste.back`); hotkey registration result; Shelf reveal, drag-out and drop-in outcome; trigger buffer match result (matched yes/no only); permission state transitions; retention sweep result (rows and bytes removed); database open, migrate, integrity-check results; every Warning/Error/Fatal raised.
- **FR-000-12** Performance signposts (`OSSignposter`, category `perf`) mark the PRD metrics: `capture.persist`, `library.open`, `library.search`, `paste.back`, `shelf.reveal`, `retention.sweep`, `trigger.expand`, `retention.clearHistory` (one interval for the whole Clear history operation, FRD-007 FR-007-16), `screenshot.import` (one interval per screenshot pickup, from the stability check to the ingest result, on every outcome including a skipped or failed file, FRD-002 FR-002-14). `paste.back` times only a paste that posts ⌘V; a copy-only paste is not timed. Signposts carry no content. They are the measurement source for the p95 targets in other FRDs.

**FR-000-11 callsite checklist.** One row per mandatory callsite. The owning module's ticket adds the `LogEvent` call (`LogEvent.swift`, one case each, typed payload so a callsite cannot log more than code or outcome). Tick a row only when the call is in the owning module's code. Status as of 2026-11-17.

| Callsite | `LogEvent` case | Owning FR | Owning ticket | Done |
|---|---|---|---|---|
| Pasteboard change processed: skipped + `POL` code | `pasteboardProcessed` | FR-001-04 | TASK-121 | [ ] |
| Pasteboard change processed: stored / deduped | `pasteboardProcessed` | FR-007-05 | TASK-051 | [ ] |
| Screenshot import outcome | `screenshotImported` | FR-002-09 | TASK-219 | [ ] |
| Screenshot reconcile-scan outcome | `screenshotScanned` | FR-002-08 | TASK-445 | [x] |
| Paste-back start and outcome | `pasteBack` (`started`, then outcome) | FR-003-15 | TASK-187 | [x] |
| Copy-only paste start and outcome | `pasteCopy` (`started`, then outcome) | FR-003-15 | TASK-455 | [x] |
| Hotkey registration result | `hotkeyRegistered` | FR-005-03 | TASK-305 | [x] |
| Shelf reveal, drag-out, drop-in outcome | `shelf` | FR-006-18 | TASK-295 | [ ] |
| Trigger buffer match result (yes/no only) | `triggerMatched` | FR-005-12 | TASK-323 | [x] |
| Permission state transitions | `permissionChanged` | FR-008-13 | TASK-105 | [x] |
| Retention sweep result (rows, bytes) | `retentionSwept` | FR-007-09 | TASK-059 | [x] |
| Database open | `database(.open)` | FR-007-02 | TASK-045 | [x] |
| Database migrate | `database(.migrate)` | FR-007-17 | TASK-075 | [x] |
| Database integrity check | `database(.integrityCheck)` | FR-007-13 | TASK-067 | [x] |
| Every Warning / Error / Fatal raised | `FlotsamLog.log(error)` via `ErrorReporter` | FR-000-08 | TASK-027 | [x] |

What each ticked row logs (outcome or count only, never an item, a path, a typed word or a trigger):
- **Screenshot scan:** `screenshot.scan` once per reconcile scan (launch, wake, activation, folder change), `succeeded` or `failed`, with the number of files it queued; never a file name.
- **Paste-back:** `paste.back started` when a paste begins (Library choice, Shelf paste, item hotkey); then one closing line, `succeeded` (pasted), `denied` (copied only because Accessibility is not granted) or `failed` (any error). A copy-only paste (⇧Return, Copy) never pastes, so it logs `paste.copy started` then `succeeded` or `failed` instead, and is never `denied` because it does not ask for Accessibility.
- **Hotkey registration:** one line per attempt, `registered` or `failed`.
- **Trigger match:** `matched` when a word expands. `noMatch` is logged when a typed word equals a trigger but expansion is suppressed (Secure Event Input, excluded app, input method, unknown app). A word that equals no trigger is decided on the key-event thread, which does no I/O (FRD-005 FR-005-21), and is not logged.
- **Permission change:** one line per permission whose granted state differs from the last time the app looked (at launch, then each time the app becomes active). The launch reading is a baseline and logs nothing.
- **Retention sweep:** one line per sweep with the rows and bytes removed by the time pass and the image-budget pass together; a sweep that removes nothing logs 0 and 0.
- **Database:** `database.integrityCheck` `passed` or `failed` (before opening an existing file, and again after migration), `database.migrate` `migrated` when a migration ran or `failed`, and `database.open` `opened` or `failed`.

**Diagnostics**
- **FR-000-13** An in-memory ring buffer holds the last 100 raised Warning, Error and Fatal errors (code, severity, timestamp). Info codes are logged but never recorded, so a high-frequency Info skip cannot evict real failures. Throttled occurrences are still recorded: the FR-000-08 throttle limits surfacing only. It is never written to disk and is cleared on quit.
- **FR-000-14** Settings › About › "Copy Diagnostics" builds a plain-text report on user action only: app version and build, macOS version, CPU architecture, permission states (Accessibility, Input Monitoring, screenshot folder access, pasteboard access), setting values that are not content (retention preset, budget preset, toggle states; never ignored-app lists), item counts by kind, database and blob byte sizes, and the ring buffer. It is copied to the clipboard marked with the pasteboard types in FR-001-03 so Flotsam does not capture its own report. It is never sent anywhere.
  *Ownership.* FRD-000 owns the snapshot builder (`DiagnosticsSnapshotBuilder`), the renderer and the copier, so a complete, redacted report can be produced from current state. The Settings › About "Copy Diagnostics" button and its "Diagnostics copied" HUD are owned by FRD-008 FR-008-09 (TASK-097, with tests in TASK-098); that ticket calls `DiagnosticsSnapshotBuilder.report()` and `DiagnosticsCopier.copy`. Permission states, item counts and file sizes come through `DiagnosticsDataSource`, which Capture, Shortcuts and Storage implement in their own tickets. AC-000-06 is verified end to end once TASK-097 lands.
- **FR-000-15** No third-party crash reporting, analytics or logging service is linked (A4). macOS-generated crash reports are the only crash data.

## 4. Data Requirements
- `ErrorCode` enum (single source, raw value = the code string). `Severity` enum. Catalogue file `Localizable.xcstrings`.
- Ring buffer entry: `{code, severity, timestamp}`. No persisted error data.

## 5. Business Rules
- Severity belongs to the code, not the call site.
- A code is added in the same commit as the first call site that raises it, with its catalogue string (Rule 7/9).
- An `Info` code with no user message is the only case allowed to have no catalogue entry (marked `—`).

## 6. Error States
This FRD defines the mechanism; its own failure modes: catalogue key missing at runtime → show `error.SYS-INT-001` text and log `SYS-INT-001` (unit test FR-000-07 prevents this shipping).

## 7. Error Catalogue (all codes, grouped by module)
Columns: code · severity · user message (catalogue text) · recovery. `{n}` = count, `{limit}` = size. A raise supplies them as safe context: `count` for `{n}`, `limitBytes` for `{limit}` (the one key for a ceiling; `byteSize` is a different quantity, such as free space, and is log-only). Context a row's text has no placeholder for is log-only and never changes the message. Info and retired rows have no user message.

**SYS**
| Code | Sev | User message | Recovery |
|---|---|---|---|
| SYS-INT-001 | Error | Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About. | propagate, HUD |

**CAP** (FRD-001)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| CAP-PRM-001 | Warning | macOS is blocking Flotsam from reading copied items. Allow Flotsam under Paste from Other Apps in System Settings. | capture suspended; Notice; retry on app activation |
| CAP-OS-001 | Warning | Flotsam couldn't read the clipboard just now. It will keep trying. | skip tick, retry next poll |
| CAP-OS-002 | Info | — | source app recorded as Unknown |
| CAP-POL-001 | Info | — | skipped: transient or auto-generated pasteboard marker, or a concealed copy that cannot be kept securely (empty or whitespace-only plain text, or no secure vault) |
| CAP-POL-002 | Info | — | skipped: source app is on the ignored list |
| CAP-POL-003 | Info | — | skipped: capture paused, or curated mode without explicit save |
| CAP-POL-004 | Info | — | skipped: Flotsam's own pasteboard write |
| CAP-VAL-001 | Info | — | skipped: empty, whitespace-only, or unsupported payload |
| CAP-DAT-001 | Info | — | skipped: copied file no longer exists |
| CAP-LIM-001 | Warning | A copy was too large to save (over {limit}). It is still on your clipboard. | skip item; Notice |
| CAP-LIM-002 | Info | — | rich representation dropped, plain text kept |
| CAP-LIM-003 | Warning | A copy of {n} files was trimmed to the first 500. | keep first 500; Notice |
| CAP-IO-001 | Error | Flotsam couldn't save a copy. The disk may be full or its data folder unreadable. | item not stored; Notice |

**SSP** (FRD-002)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| SSP-PRM-001 | Warning | Flotsam can't read your screenshot folder. Allow access in System Settings › Privacy & Security › Files and Folders. | pickup idle; retry every 30 s and on activation |
| SSP-IO-001 | Warning | Your screenshot folder isn't available, so Flotsam is watching the Desktop instead. | fall back to ~/Desktop |
| SSP-IO-002 | Info | — | file unstable or unreadable within 5 s; skipped |
| SSP-IO-003 | Warning | Your chosen screenshot folder is missing. Screenshot pickup is paused. | paused until folder returns |
| SSP-VAL-001 | Info | — | not a decodable image; skipped |
| SSP-LIM-001 | Warning | A screenshot was too large to import (over {limit}). | skip file; Notice |
| SSP-OS-001 | Warning | Live screenshot watching isn't working. Flotsam is checking every 5 seconds instead. | directory poll fallback |

**LIB** (FRD-003)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| LIB-OS-001 | Error | Couldn't paste into that app. The item is on your clipboard; press ⌘V. | item left on pasteboard; HUD |
| LIB-IO-001 | Error | This item's data is missing, so it was removed. | delete item; HUD |
| LIB-DAT-001 | Warning | The original file or folder has moved or been deleted. | no paste; HUD; row marked Missing |
| LIB-OS-002 | Warning | Not copied. Confirm it's you to copy a secure item. | nothing written to the pasteboard; HUD |
| LIB-DAT-002 | Warning | This secure item can't be unlocked on this Mac. | no copy; HUD; row marked Unavailable |

**ORG** (FRD-004)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| ORG-VAL-001 | Error | Tag names must be 1 to 32 characters and unique. | edit rejected inline |
| ORG-VAL-002 | Error | Notes can be up to 2,000 characters. | edit rejected inline |
| ORG-VAL-003 | Error | Only text items can be edited, and they can't be empty. | edit rejected |
| ORG-VAL-004 | Error | Choose 2 to 500 files or folders to group. | group rejected, HUD (reinstated 2026-11-19: FRD-004 FR-004-41) |
| ORG-VAL-005 | Error | Bundle names can be up to 100 characters. | rename rejected inline (reinstated 2026-11-19: FRD-004 FR-004-42) |
| ORG-LIM-001 | Error | An item can have up to 10 tags. | assignment rejected |
| ORG-LIM-002 | Error | You can have up to 100 tags. | creation rejected |
| ORG-LIM-003 | Error | That text is over the {limit} limit. Shorten it and try again. | edit rejected inline |

**TRG** (FRD-005)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| TRG-VAL-001 | Error | Triggers start with a symbol (like ;), have 2 to 24 characters and contain no spaces. | rejected inline |
| TRG-VAL-002 | Error | That trigger is already used by another item. | rejected inline |
| TRG-VAL-003 | Error | Shortcuts need ⌘ or ⌃ plus a key, and can't be a reserved system shortcut. | rejected inline |
| TRG-VAL-004 | Error | That shortcut is already used in Flotsam. | rejected inline |
| TRG-VAL-005 | Warning | An unknown variable was left as plain text. | saved; inline notice |
| TRG-VAL-006 | Error | Secure items can't have a trigger or a shortcut. | rejected inline |
| TRG-OS-001 | Error | macOS wouldn't let Flotsam use that shortcut. Try a different one. | not registered; kept for retry |
| TRG-OS-002 | Error | Couldn't expand that trigger. Your typed text was left as it was. | abort expansion; HUD |
| TRG-OS-003 | Warning | Typed triggers were paused by macOS and have been restarted. | re-enable tap; Notice |
| TRG-POL-001 | Info | — | expansion suppressed: secure input active |
| TRG-POL-002 | Info | — | expansion suppressed: frontmost app excluded |

**SHF** (FRD-006)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| SHF-OS-001 | Error | Couldn't drag that item out. Try again or paste it from the Library. | cancel drag; HUD |
| SHF-IO-001 | Warning | A dropped file couldn't be read and was skipped. | skip file; HUD |
| SHF-LIM-001 | Warning | A dropped item was too large to save (over {limit}). | skip item; HUD |
| SHF-VAL-001 | Warning | Flotsam can't store that kind of content. | reject drop; HUD |

**STO** (FRD-007)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| STO-DB-001 | Error | Flotsam couldn't save your history. Free up disk space and try again. | roll back; surface per FR-000-08 |
| STO-DB-002 | Error | Your history database was damaged. A fresh one was created and the old file was kept in the data folder. | move aside, recreate; Notice |
| STO-DB-003 | Fatal | Flotsam can't open its history after an update. Your data is untouched; reinstall the previous version or reveal the data folder. | alert, quit |
| STO-DB-004 | Error | Couldn't read your history. Try again. | propagate |
| STO-IO-001 | Error | Flotsam couldn't write to its data folder. Check free disk space. | operation aborted |
| STO-IO-002 | Fatal | Flotsam can't create its data folder, so it can't run. | alert, quit |
| STO-IO-003 | Info | — | orphan blob or missing blob found during reconcile; repaired |
| STO-LIM-001 | Warning | Pinned and shortcut items alone exceed your image budget. | no eviction of exempt items; Notice |
| STO-LIM-002 | Warning | Disk space is low, so Flotsam isn't saving images. | skip image ingest; Notice |
| STO-POL-001 | Info | — | retention or budget sweep removed rows (counts logged) |

**SET** (FRD-008)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| SET-PRM-001 | Warning | Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V. | copy-only fallback |
| SET-PRM-002 | Warning | Input Monitoring is off, so typed triggers are paused. Turn it on in System Settings › Privacy & Security. | triggers inert |
| SET-OS-001 | Error | Couldn't change Launch at Login. Check System Settings › General › Login Items. | revert toggle; HUD |
| SET-OS-002 | Error | Couldn't start local AI access, so it was turned off. Check that Flotsam's data folder is available, then turn it on again. | switch reverts to off |
| SET-VAL-001 | Error | That folder can't be used for screenshots. Choose a folder you can read. | rejected |
| SET-VAL-002 | Error | That isn't an app Flotsam can add. Choose an application. | rejected |
| SET-DAT-001 | Warning | A setting had an invalid value and was reset to its default. | reset; Notice |

## 8. Acceptance Criteria
- **AC-000-01** (FR-000-01,02) Given any module's public API, when its signature is inspected, then every fallible function returns `Result<_, FlotsamError>`; a lint rule fails the build on `try!`, `as!`, `!` on external data, and `fatalError` outside FR-000-04 sites.
- **AC-000-02** (FR-000-07) Given the code enum and the catalogue, when the unit test runs, then it passes only if the sets are identical, all Warning/Error/Fatal messages ≤ 140 chars, and no Info code has a message.
- **AC-000-03** (FR-000-10) Given a debug run that copies a unique marker string, a marker URL, a marker file name and sets a marker tag and trigger, when `log show --last 5m --info --debug --predicate 'subsystem == "<bundle id>"'` and the diagnostics report are searched for the markers, then zero matches.
- **AC-000-04** (FR-000-08) Given the same background error raised 10 times in 30 s, then the log shows 10 entries and the Notices list shows 1.
- **AC-000-05** (FR-000-04) Given `STO-IO-002` is raised, then the alert offers exactly "Reveal Data Folder" and "Quit" and the process exits after dismissal; given any other code is raised, the process stays alive.
- **AC-000-06** (FR-000-14) Given "Copy Diagnostics", then the clipboard receives text containing every field in FR-000-14 and no item content, and Flotsam does not add that clipboard change to history.
- **AC-000-07** (FR-000-12) Given a release build, then Instruments' signpost lanes show all nine named intervals during a scripted session.
- **AC-000-08** (FR-000-09) Given a release build, then `#if DEBUG` traces are absent from the binary's logs and `print`/`NSLog` do not appear in app sources.

## 9. UI Inventory
| Element | Type | Where | Behavior |
|---|---|---|---|
| HUD | transient floating label | top-centre of pointer's screen | message text, 2.5 s, no focus, VoiceOver announces |
| Menu-bar badge dot | icon overlay | menu-bar icon | shown while unacknowledged Warning/Error Notices exist |
| Notices submenu | menu | menu bar › Notices | up to 10 entries: message text and code in secondary text (a menu-style menu cannot style a second line, so each row reads "message · CODE" on one line); "Dismiss all" |
| Fatal alert | modal NSAlert | centre | message, "Reveal Data Folder" (nearest existing ancestor if the folder is missing), "Quit" |
| Copy Diagnostics button | button | Settings › About | builds and copies report; confirms with HUD "Diagnostics copied" |
| Inline validation text | label | beside the invalid field | catalogue message, red text plus icon, role alert for VoiceOver |

## 10. Out of Scope
Localization beyond English (structure supports it, v1 ships English only); remote logging or crash upload (A4); user-visible log viewer; persisted error history.

## 11. Change Log
- 2026-11-19: §7 gains `SET-OS-002` (the local AI access server could not start; the switch returns to off), FRD-010 FR-010-01.
- 2026-11-18: §7 gains `LIB-OS-002` (a secure item's copy was not authorised), `LIB-DAT-002` (a secure item's key is missing or its bytes do not open) and `TRG-VAL-006` (a secure item cannot carry a shortcut or trigger), for secure clips (FRD-001 FR-001-25). 63 live codes: 2 Fatal, 22 Warning, 25 Error, 14 Info.
- 2026-11-18: FR-000-05: a plural count is a whole number in any form, including a boxed one (`NSNumber`): exactly 1 reads `one`; anything else reads `other`. A decimal (1.0, 1.5), text, a missing count and a yes/no value (even one that boxes to 1) are not counts and read `other`.
- 2026-11-18: FR-000-12: `screenshot.import` added, a ninth interval, one per screenshot pickup (FRD-002 FR-002-14 is measured with it).
- 2026-11-18: FR-000-11/12: a copy-only paste (⇧Return) logs `paste.copy`, not `paste.back`, and is not timed by the `paste.back` signpost (it posts no ⌘V). FR-000-08: Notices raised for a missing trigger permission or a tap that would not install clear when that condition ends, so the menu-bar warning dot does not outlive the problem.
- 2026-11-18: FR-000-11: eight more callsites ticked (paste-back, hotkey registration, trigger no-match, permission transition, retention sweep, database open, migrate and integrity check); the lines each one writes are listed under the checklist. A trigger no-match is logged only for a typed word that equals a trigger but is suppressed; ordinary words are not logged.
- 2026-11-18: FR-000-11: screenshot reconcile-scan outcome added as a mandatory callsite (`screenshotScanned`, ticked), logged by FRD-002 FR-002-08.
- 2026-11-18: FR-000-08: clearing a code's Notices on recovery also clears that code's 60 s throttle, so a condition that returns within 60 s (suspend, resume, suspend again) shows its Notice again.
- 2026-11-17: FR-000-05/06 and FR-000-08 (8A rulings): argument kinds must match message specifiers (checked); a wrong kind shows the SYS-INT-001 text instead of crashing; long app names are cut with "…" to fit 140 characters; negative values show as 0 and zero shows in digits; a surfacing time later than now (clock set back) counts as expired in the throttle.
- 2026-11-16: FR-000-08 states the throttle boundary: a surfacing exactly 60 s old has expired, so the same code may surface again at T+60.
- 2026-11-16: STO-DB-003 copy cut from three sentences to two (the 1-2 sentence rule): "Flotsam can't open its history after an update. Your data is untouched; reinstall the previous version or reveal the data folder."
