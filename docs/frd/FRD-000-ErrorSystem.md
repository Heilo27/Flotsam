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
- **FR-000-03** Code format: `<MOD>-<CAT>-<NNN>`. Modules: `SYS` core, `CAP` capture (FRD-001), `SSP` screenshot pickup (FRD-002), `LIB` library (FRD-003), `ORG` organize (FRD-004), `TRG` shortcuts and triggers (FRD-005), `SHF` shelf (FRD-006), `STO` storage and retention (FRD-007), `SET` settings, onboarding, permissions (FRD-008). Categories: `PRM` permission, `IO` file or disk, `DB` database, `VAL` validation of user input or external data, `LIM` size or count limit, `OS` system API failure, `POL` expected skip by policy (always Info), `DAT` data-state inconsistency, `INT` internal. Numbers are three digits, per module+category, never reused or renumbered; a retired code stays in §7 marked `retired`.

**Severity and recovery**
- **FR-000-04** Four severities, fixed per code in §7:
  - **Fatal** — Flotsam cannot run safely. Show a modal alert with the user message, a "Reveal Data Folder" button and a "Quit" button, then terminate. If the data folder does not exist (`STO-IO-002`), "Reveal Data Folder" reveals its nearest existing ancestor and never creates the folder. Closed list: `STO-IO-002`, `STO-DB-003`. No other code may be Fatal.
  - **Error** — the user's action or a background save failed. Propagate to the caller, surface per FR-000-08, never crash.
  - **Warning** — the app is degraded but working (permission off, limit hit, fallback active). Log at notice, continue, surface per FR-000-08.
  - **Info** — an expected, policy-driven or benign skip (for example a concealed pasteboard item). Log only; never shown to the user and never recorded in the ring buffer (FR-000-13).

**Catalogue and strings**
- **FR-000-05** One catalogue: the Xcode String Catalog `Localizable.xcstrings`. Every user-facing string in the app (errors and normal UI) is a catalogue key; no user-facing string literal appears in a view or model. Error messages use keys `error.<code>` (for example `error.SET-PRM-001`). Source language English; plural and count variations use catalogue variations, not string concatenation.
- **FR-000-06** Message style: one or two sentences, ≤ 140 characters, states what happened then what to do, no jargon, no blame, no error code inline. A message may interpolate only: counts, byte sizes, durations, permission names, and the display name of an app. It may never interpolate clip text, URLs, file or folder names, notes, tags, trigger strings or search queries.
- **FR-000-07** The §7 table is the specification of the catalogue. A unit test enumerates every `ErrorCode` and fails if any code lacks a catalogue key (Warning/Error/Fatal), has a duplicate raw value, has a catalogue key with no code, or has a message over 140 characters.

**Surfaces**
- **FR-000-08** Surfacing rule. (a) User-initiated action fails (paste, hotkey, edit, drop, expansion): show a HUD — a small non-activating floating label, top-centre of the screen with the pointer, 2.5 s, no focus change. (b) Background failure (capture, screenshot pickup, retention): add a dot badge to the menu-bar icon and append to the Notices list (menu bar › Notices, newest 10 kept in memory, cleared on "Dismiss all" or quit). (c) Fatal: modal alert (FR-000-04). Throttle: the same code surfaces at most once per 60 s and at most 3 HUDs per minute overall; throttled occurrences are still logged.

**Logging**
- **FR-000-09** Logging uses `os.Logger`, subsystem = the app bundle identifier, one category per module (`core`, `capture`, `screenshots`, `library`, `organize`, `triggers`, `shelf`, `storage`, `settings`). Level mapping: Info → `.info`, Warning → `.notice`, Error → `.error`, Fatal → `.fault`. Verbose traces use `.debug` and are wrapped in `#if DEBUG` so they are compiled out of release builds. `print`, `NSLog` and `dump` are forbidden in app sources (lint-enforced).
- **FR-000-10** Content never appears in any log, error context, signpost, Notice or diagnostics report. Forbidden: clip text, URLs, colours, phone numbers, emails, file and folder names or paths of user items, screenshot file names, bundle names, notes, tag names, trigger strings, search queries, typed-key buffers. Every dynamic value interpolated into a log string carries an explicit privacy qualifier: `.private` by default; `.public` only for the allowlist — error code, severity, item kind, counts, byte sizes, durations, booleans, enum raw values, system-declared pasteboard type identifiers (UTIs), OS and app versions. Source-app bundle identifiers, and any pasteboard type identifier that is not system-declared (an app's own type, a `dyn.` identifier), are `.private`; the log context types accept only a validated bundle identifier and a classified type identifier, never a free string.
- **FR-000-11** Mandatory instrumented callsites (each logs code or outcome only): pasteboard change processed (kind, byte size, outcome: stored / deduped / skipped + `POL` code); screenshot import outcome; paste-back start and outcome; hotkey registration result; Shelf reveal, drag-out and drop-in outcome; trigger buffer match result (matched yes/no only); permission state transitions; retention sweep result (rows and bytes removed); database open, migrate, integrity-check results; every Warning/Error/Fatal raised.
- **FR-000-12** Performance signposts (`OSSignposter`, category `perf`) mark the PRD metrics: `capture.persist`, `library.open`, `library.search`, `paste.back`, `shelf.reveal`, `retention.sweep`, `trigger.expand`. Signposts carry no content. They are the measurement source for the p95 targets in other FRDs.

**FR-000-11 callsite checklist.** One row per mandatory callsite. The owning module's ticket adds the `LogEvent` call (`LogEvent.swift`, one case each, typed payload so a callsite cannot log more than code or outcome). Tick a row only when the call is in the owning module's code. Status as of 2026-11-17.

| Callsite | `LogEvent` case | Owning FR | Owning ticket | Done |
|---|---|---|---|---|
| Pasteboard change processed: skipped + `POL` code | `pasteboardProcessed` | FR-001-04 | TASK-121 | [ ] |
| Pasteboard change processed: stored / deduped | `pasteboardProcessed` | FR-007-05 | TASK-051 | [ ] |
| Screenshot import outcome | `screenshotImported` | FR-002-09 | TASK-219 | [ ] |
| Paste-back start and outcome | `pasteBack` (`started`, then outcome) | FR-003-15 | TASK-187 | [ ] |
| Hotkey registration result | `hotkeyRegistered` | FR-005-03 | TASK-305 | [ ] |
| Shelf reveal, drag-out, drop-in outcome | `shelf` | FR-006-18 | TASK-295 | [ ] |
| Trigger buffer match result (yes/no only) | `triggerMatched` | FR-005-12 | TASK-323 | [ ] |
| Permission state transitions | `permissionChanged` | FR-008-13 | TASK-105 | [ ] |
| Retention sweep result (rows, bytes) | `retentionSwept` | FR-007-09 | TASK-059 | [ ] |
| Database open | `database(.open)` | FR-007-02 | TASK-045 | [ ] |
| Database migrate | `database(.migrate)` | FR-007-17 | TASK-075 | [ ] |
| Database integrity check | `database(.integrityCheck)` | FR-007-13 | TASK-067 | [ ] |
| Every Warning / Error / Fatal raised | `FlotsamLog.log(error)` via `ErrorReporter` | FR-000-08 | TASK-027 | [x] |

**Diagnostics**
- **FR-000-13** An in-memory ring buffer holds the last 100 raised Warning, Error and Fatal errors (code, severity, timestamp). Info codes are logged but never recorded, so a high-frequency Info skip cannot evict real failures. It is never written to disk and is cleared on quit.
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
Columns: code · severity · user message (catalogue text) · recovery. `{n}` = count, `{limit}` = size. Info rows have no user message.

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
| CAP-POL-001 | Info | — | skipped: concealed, transient or auto-generated pasteboard marker |
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

**ORG** (FRD-004)
| Code | Sev | User message | Recovery |
|---|---|---|---|
| ORG-VAL-001 | Error | Tag names must be 1 to 32 characters and unique. | edit rejected inline |
| ORG-VAL-002 | Error | Notes can be up to 2,000 characters. | edit rejected inline |
| ORG-VAL-003 | Error | Only text items can be edited, and they can't be empty. | edit rejected |
| ORG-VAL-004 | retired | — (retired 2026-11-16: no group action exists; FRD-004 offers ungroup only) | never raised |
| ORG-VAL-005 | retired | — (retired 2026-11-16: no rename exists; tag names use ORG-VAL-001) | never raised |
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
| STO-DB-003 | Fatal | Flotsam can't open its history after an update. Your data is untouched. Reinstall the previous version or reveal the data folder. | alert, quit |
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
- **AC-000-07** (FR-000-12) Given a release build, then Instruments' signpost lanes show all seven named intervals during a scripted session.
- **AC-000-08** (FR-000-09) Given a release build, then `#if DEBUG` traces are absent from the binary's logs and `print`/`NSLog` do not appear in app sources.

## 9. UI Inventory
| Element | Type | Where | Behavior |
|---|---|---|---|
| HUD | transient floating label | top-centre of pointer's screen | message text, 2.5 s, no focus, VoiceOver announces |
| Menu-bar badge dot | icon overlay | menu-bar icon | shown while unacknowledged Warning/Error Notices exist |
| Notices submenu | menu | menu bar › Notices | up to 10 entries: message text and code in secondary text (a menu-style menu cannot style a second line, so the code follows the message on the same line); "Dismiss all" |
| Fatal alert | modal NSAlert | centre | message, "Reveal Data Folder" (nearest existing ancestor if the folder is missing), "Quit" |
| Copy Diagnostics button | button | Settings › About | builds and copies report; confirms with HUD "Diagnostics copied" |
| Inline validation text | label | beside the invalid field | catalogue message, red text plus icon, role alert for VoiceOver |

## 10. Out of Scope
Localization beyond English (structure supports it, v1 ships English only); remote logging or crash upload (A4); user-visible log viewer; persisted error history.
