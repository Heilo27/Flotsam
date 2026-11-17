# Flotsam Architecture

Status: Phase 7, 2026-11-16. Decisions and their reasoning are in [docs/adr/](adr/README.md); this document is the map.
Truths: [TRUTHS.md](TRUTHS.md). Requirements: [PRD](PRD.md), [FRD-000..008](frd/).

## 1. Forces

| Force | Consequence |
|---|---|
| Primary truth: recall in under 3 s, nothing leaves the Mac | One local database, no network API anywhere (grep-enforced), search must stay fast at 10k items |
| Not sandboxed (CGEventTap, Accessibility paste-back, arbitrary screenshot folders) | Platform code is real system access; it is quarantined in one folder behind ports |
| Changes often: UI, copy, defaults, the dogfood-tuned timings | These live in the app target, the strings catalogue, the settings registry and `PasteTiming` |
| Stable: item schema, ingest rules, retention rules, error codes | These live in the package, tested without UI |
| Risky and unmeasured: nine spikes (S-1..S-9) | Each risk is isolated to one adapter or one constant, so a spike result never reshapes the module graph (section 9) |
| Small team, public MIT repo | Tiny dependency list (GRDB only), generated Xcode project, architecture checks in one script |

## 2. Shape

One Swift package, `Packages/FlotsamCore`, holds all behaviour and is testable with `swift test` and no UI. One app target, `Flotsam`, holds SwiftUI and AppKit views, the `NSPanel` windows, the status item and the **platform adapters** (`App/Platform/`) that implement the package's port protocols.

The package is layered. A module may import only modules in a lower layer; features never import features.

```
L4  App/Flotsam (UI, panels, status item, composition root)  +  App/Platform (adapters)
L3  Capture  Screenshots  Library  Shortcuts  Triggers  Shelf      (features, mutually independent)
L2  Paste
L1  Storage (GRDB)      Payload
L0  Base (errors, logging, strings, settings registry, ports, shared value types)
```

Module targets are named `Flotsam<Module>` (for example `FlotsamStorage`); this document uses the short names.

## 3. Module map (AC1)

Every FRD maps to a module and its owner FRs. A requirement has exactly one owning module; "UI in app" means the view layer, whose behaviour rules sit in the named module.

| FRD | Module(s) | Owner FRs |
|---|---|---|
| **FRD-000** Errors | Base | FR-000-01..07 (error type, codes, severity, catalogue, test). Surfacing (HUD, Notices menu, Fatal alert, FR-000-08 onward): App; the severity and routing table is in Base |
| **FRD-001** Capture | Capture | FR-001-01, -02 (poll, immediate polls), -04 (policy gates), -13 (source app), -14 (remote clipboard), -17 (hand-off), -18 (pasteboard privacy), -19 (mode behaviour), -20..22 |
| | Payload | FR-001-05..12 (honoured types, kinds, typed-text, rich text, images, files and bundles), -15 (dedupe key) |
| | Paste | FR-001-03 (own-write markers) |
| | Storage | FR-001-16 (ceilings, via `IngestLimits`) |
| **FRD-002** Screenshot pickup | Screenshots | FR-002-01..15. Import goes through Storage's ingest (FR-007-05); FSEvents adapter in `App/Platform` (ADR-0008) |
| **FRD-003** Library | Library | FR-003-04, -08 (keyboard map as data), -09..11 (search semantics, counts), -12 (sidebar model), -20 |
| | Paste | FR-003-15..17 (paste sequence, mismatch, no Accessibility) |
| | Storage | FR-003-13 (thumbnail cache), -10 (query performance, with FR-007-18) |
| | App (UI) | FR-003-01..03, -05..07, -14, -18, -19, -21, -22 (window, layout, rendering, preview, accessibility) |
| **FRD-004** Organize | Library | FR-004-01..14 (pin, tags, note, edit, delete, ungroup, filter and sort models, counts; each action is one Storage transaction) |
| **FRD-005** Shortcuts and triggers | Shortcuts | FR-005-01..09 (registry, binding rules, registration, recorder rules, item hotkey, Save Clipboard, Toggle Shelf, trigger grammar, assignment) |
| | Triggers | FR-005-10..21 (activation, buffer, matching, suppression, expansion, variables, tap health, keystroke privacy) |
| | Shortcuts and Triggers | FR-005-22 (lifecycle links): each reacts to Storage item-change events; the event stream is designed with the FRD-005 build ticket |
| **FRD-006** Shelf | Shelf | FR-006-01, -04, -06, -08, -10..14, -16..18 (enablement, hide rules, contents, drag accounting, drop rules and processing) |
| | Payload | FR-006-13 (a drop is classified and keyed exactly like a capture) |
| | App (UI) | FR-006-02, -03, -05, -07, -09, -15, -19, -20 (panel, reveal, geometry, cards, feedback, screens) |
| **FRD-007** Storage | Storage | FR-007-01..11, -13..18 (folder, database, schema, blobs, ingest, limits, images, budget, retention, exemptions, clear, integrity, disk guard, deletion, performance, migrations, query layer) |
| | Base | FR-007-12 (the `capture.mode` key and enum); enforcement is in Capture and Screenshots |
| **FRD-008** Onboarding and settings | Base | FR-008-01, -02 (registry, persistence, validation, change delivery), -11 (default ignored-apps list) |
| | App (UI) | FR-008-03..10, -12, -14 (panes, onboarding, copy-only fallback UI), -15 (`SMAppService`), -16 (menu bar), -17 |
| | Check script | FR-008-18 (zero network) via `bin/check-architecture.sh` |

## 4. Dependency rules (AC3)

Enforced by Swift's target graph (a missing dependency fails to compile) and, for what the compiler cannot see, by `bin/check-architecture.sh`.

1. **Downward only.** Imports follow the layer diagram; no upward import, no cycle.
2. **Allowed imports per target:**

| Target | May import |
|---|---|
| Base | Foundation, os |
| Storage | Base, GRDB |
| Payload | Base, CryptoKit |
| Paste | Base, Storage |
| Capture, Screenshots, Shelf | Base, Storage, Payload |
| Library, Shortcuts, Triggers | Base, Storage, Paste |
| App | every package product, SwiftUI, AppKit, Carbon, CoreGraphics, ApplicationServices, ServiceManagement |

3. **Features never import features.** Anything two features share is pushed down: classification and keying to Payload, paste sequencing to Paste, search normalisation to Base.
4. **The package has no UI or platform imports.** No AppKit, SwiftUI, Carbon, ApplicationServices, ServiceManagement, CoreGraphics event APIs. System access is a port in Base implemented in `App/Platform/`.
5. **Only Storage imports GRDB or SQLite.** No other module knows a table name.
6. **Zero network.** No `URLSession`, `NWConnection`, `NWPathMonitor`, `WKWebView`, CFNetwork or Sparkle in package or app.
7. **No `print`, `NSLog`, `dump`, `try!`;** `UserDefaults` is touched only by the `KeyValueStore` adapter.
8. **Dependencies:** GRDB only; additions need an ADR amendment ([ADR-0010](adr/0010-dependency-allowlist.md)).
9. **Swift 6 language mode and complete strict concurrency** in every target.

## 5. Concurrency ([ADR-0004](adr/0004-concurrency-model.md))

MainActor owns UI and the 0.5 s pasteboard poll, which only compares `changeCount`, runs the gates and copies bytes. An immutable `Sendable` `CapturedPayload` then goes to a serial `IngestActor` in Storage, which hashes, classifies, converts and writes in one transaction. The database is a GRDB `DatabasePool` with async-only access. The CGEventTap runs on its own run-loop thread with a thread-confined matcher. The paste coordinator, screenshot watcher, retention scheduler and settings store each have one isolation domain. Timers use an injected clock. `@unchecked Sendable` and `nonisolated(unsafe)` are permitted only for the tap-thread context, the trigger snapshot holder and the `UserDefaults` in `UserDefaultsStore`.

Open item: whether reading a large image's bytes off the main actor is safe for `NSPasteboard` is unverified (belongs to S-4's remit).

## 6. Persistence ([ADR-0002](adr/0002-sqlite-binding-grdb.md), [ADR-0003](adr/0003-search-strategy.md))

SQLite through GRDB (`DatabasePool`, system SQLite), blobs on disk.

Folder `~/Library/Application Support/Flotsam/` (directory 0700, files 0600):

```
flotsam.sqlite (+ -wal, -shm)   blobs/<first 2 chars of itemId>/<itemId>.<n>   thumbs/   tmp/
corrupt-<timestamp>/            pre-migration/flotsam-v<N>.sqlite
```

Pragmas: `journal_mode=WAL`, `synchronous=NORMAL`, `foreign_keys=ON`, `secure_delete=ON`, `busy_timeout=5000`. Blob write order: write to `tmp/`, flush, atomic rename, then commit the row.

Schema sketch (FRD-007 FR-007-03 is the single definition; this is the architectural shape). Times are UTC milliseconds. "Exempt from retention" is derived: pinned, or has a trigger, or has a hotkey.

| Table | Columns (summary) |
|---|---|
| `item` | `id` UUID text PK; `kind`; `createdAt`; `lastCopiedAt`; `copyCount` (1); `pasteCount` (0); `lastUsedAt`; `contentKey` (indexed, not unique); `plainText`; `searchText`; `sourceBundleId`; `sourceName`; `byteSize`; `pixelWidth`; `pixelHeight`; `originalPath`; `pinned` (0); `note` (at most 2000); `updatedAt`; `hotkeyCode`, `hotkeyModifiers` (unique pair where not null); `trigger` (unique, case-insensitive, where not null); `exemptReleasedAt` |
| `representation` | `id`; `itemId` (cascade); `uti`; `byteSize`; `blobName` |
| `bundleMember` | `itemId` (cascade); `ordinal`; `path`; `bookmark` blob; `isDirectory` |
| `tag` | `id`; `name` (unique, case-insensitive); `color`; `createdAt` |
| `itemTag` | `itemId`, `tagId` (cascade, unique pair) |
| `meta` | `key` PK; `value` (`schemaVersion`, `screenshots.lastScanAt`, `retention.lastSweepAt`, `budget.lastNoticeAt`) |

Migrations are our own ~40-line runner over `PRAGMA user_version` with a pre-migration file copy (FR-007-17). Migration 1 is the full FRD-007 schema (item, representation, bundleMember, tag, itemTag, meta); the copy is `pre-migration/flotsam-v<from>.sqlite`, latest only.

**Search default** ([ADR-0003](adr/0003-search-strategy.md)): an in-database `instr(searchText, token) > 0` scan per token, AND-ed, tokens normalised by `SearchNormalizer`, pages of 200 rows plus a count, no resident index copy. If it exceeds 100 ms p95 at 10k items (2k images) in spike S-1, migration 2 adds an FTS5 trigram index kept in sync in the same transaction, used for tokens of 3 or more characters, with `instr` for shorter ones and an equivalence test against the scan either way.

## 7. Single-source homes ([ADR-0009](adr/0009-single-source-homes.md))

| Knowledge | Home |
|---|---|
| Error codes, severity, `FlotsamError` | Base `ErrorCode` / `FlotsamError` |
| User-facing strings | Base `Localizable.xcstrings`, via `FlotsamStrings`, keys `error.<code>` and `ui.<screen>.<name>` |
| Settings keys, defaults, validation | Base `SettingKeys` / `SettingsStore` |
| Ingest limits | Storage `IngestLimits` |
| Kinds, payload, chord, search normalisation | Base `ItemKind`, `CapturedPayload`, `Chord`, `SearchNormalizer` |
| Classification and `contentKey` | Payload |
| Screenshot name prefixes | Screenshots `ScreenshotNamePrefixes` |
| Reserved chords | Shortcuts `ReservedChords` |
| Paste timing windows | Paste `PasteTiming` |
| Schema and migrations | Storage |
| Log categories and safe values | Base `LogCategory`, `LogKey`, `LogSafeValue` |

## 8. Platform boundaries and ports

| Concern | Port (in Base) | Adapter (App/Platform) | ADR |
|---|---|---|---|
| Time | `WallClock` | `SystemClock` (in Base) | 0011 |
| Pasteboard | `PasteboardPort` (MainActor) | `NSPasteboard` adapter | 0004, 0011 |
| Files | `FileSystemPort` | `LocalFileSystem` (in Base; Foundation only) | 0011 |
| Settings storage | `KeyValueStore` | `UserDefaultsStore` (in Base) | 0009 |
| Hotkeys | `HotkeyRegistrar` | Carbon `RegisterEventHotKey` | 0006 |
| Keystrokes | `KeyEventSource`, `KeyEventPoster` | `CGEventTap` thread, `CGEvent` poster | 0007, 0005 |
| Screenshot folder events | `FolderEventSource` | FSEvents stream, 5 s polling fallback | 0008 |
| Frontmost app, permissions | `FrontmostAppProvider`, `PermissionProbe` | `NSWorkspace`, `AXIsProcessTrusted` | 0005, 0007 |

Ports marked after Base are declared when the owning FRD is built, not before (no premature abstraction).

## 9. Spike register (AC4)

| Spike | Ticket | Question | Lands in | If it fails |
|---|---|---|---|---|
| S-1 | TASK-004 | Search latency at 10k items; FTS needed? | ADR-0003 | Add FTS5 trigram as migration 2 (rule fixed in advance). Request: include the in-DB `instr` scan as a third arm |
| S-2 | TASK-005 | Default Library chord | `SettingKeys` default only | Change one registry default and FRD-005/008 table |
| S-3 | TASK-006 | Can the Shelf detect a global drag without Accessibility? | App Shelf panel; FRD-006 FR-006-03 | Fall back to hotkey or hover reveal: FRD change, no module change |
| S-4 | TASK-007 | Pasteboard privacy behaviour on current macOS | FR-001-18; `PasteboardPort` adapter | Adapter and FR-001-18 wording only |
| S-5 | TASK-008 | Carbon hotkeys without Accessibility; the option-only rule | ADR-0006; FR-008-14, FR-005-02 | Registrar adapter and FR-008-14 line |
| S-6 | TASK-009 | Default ignored-app bundle IDs | Base registry default (FR-008-11) | Edit one default list |
| S-7 | TASK-010 | Text input in a non-activating `NSPanel` | App Library panel (load-bearing for FRD-003) | Panel type changes inside App; `PasteService` unchanged ([ADR-0005](adr/0005-paste-back.md)) |
| S-8 | TASK-011 | Screenshot attribute timing and localised prefixes | ADR-0008; `ScreenshotNamePrefixes` | Prefix list becomes primary signal; one-file change |
| S-9 | TASK-012 | Permissions the active tap needs | ADR-0007; FR-005-10, FR-008-14 | `PermissionProbe` requirements only |

## 10. Test architecture ([ADR-0011](adr/0011-testing-seams.md))

Swift Testing; one test target per package target; `swift test --package-path Packages/FlotsamCore`. Storage tests open real SQLite files in a temp directory. Time is a manual `WallClock`. Coverage targets (architect's choice, not an FRD requirement): at least 90% lines on Base, Storage and Payload, at least 80% on other package targets; the app target is covered by the per-FRD UI and manual tests. The skeleton includes the error catalogue completeness test (FR-000-07), settings tests, search normaliser tests, and a Storage open test that asserts WAL, foreign keys, secure delete, `user_version`, folder permissions, the pre-migration copy, and the Fatal error mapping.

## 11. Build and project ([ADR-0012](adr/0012-project-tooling.md))

```
bin/bootstrap.sh              # xcodegen generate + resolve packages
bin/build.sh                  # bootstrap + xcodebuild, derived data in ./build (gitignored)
swift test --package-path Packages/FlotsamCore
bin/check-architecture.sh
```

`project.yml` is the single description of the app target; `Flotsam.xcodeproj` is generated and gitignored. No team ID or signing identity is committed. The bundle identifier is `io.github.heilo27.Flotsam` (a namespace the project owns through GitHub Pages); it is set in `project.yml` and the logging subsystem reads it from the bundle, with the same value as its fallback in `FlotsamLog`.

## 12. Stress: change scenarios

| Scenario | What changes | Rewrite? |
|---|---|---|
| Search is too slow | One migration plus one query function in Storage | No |
| Swap SQLite binding (GRDB to C API) | Storage internals; ports and all callers unchanged | No |
| Hotkeys need Accessibility after all (S-5) | `HotkeyRegistrar` adapter and FR-008-14 text | No |
| A third key source (for example a different tap API) | New `KeyEventSource` adapter | No |
| Add a Share-sheet from the Shelf (v1.1 candidate) | New code in App; Shelf logic unchanged | No |
| Add a new item kind | `ItemKind`, Payload classifier, one row renderer in App; migration only if a column is needed | No |
| Panel cannot take text (S-7) | App Library panel construction | No |
| Cross-platform or CLI front end | App target is replaceable; package has no UI imports | No |
| Another feature wants to reuse Library code | It does not; shared code moves down to Base, Payload or Paste (rule 3) | No |

## 13. Known gaps and open decisions

- Bundle identifier is a placeholder (section 11).
- macOS 14's bundled SQLite and FTS5 trigram availability are unverified; the dev machine's SQLite supports it (S-1 repeats the check on macOS 14).
- Off-main pasteboard reads are unverified (section 5).
- The Storage item-change event stream (FR-005-22) is not yet designed; it is part of the FRD-005 build.
- The full error catalogue (FRD-000 section 7) and the other 15 settings keys are seeded by their owning build tickets; the skeleton holds three codes and four keys so the mechanism is proven end to end.
- Coverage targets are the architect's proposal.

## 14. Decision index

[ADR-0001](adr/0001-module-structure.md) module structure · [0002](adr/0002-sqlite-binding-grdb.md) SQLite binding · [0003](adr/0003-search-strategy.md) search · [0004](adr/0004-concurrency-model.md) concurrency · [0005](adr/0005-paste-back.md) paste-back · [0006](adr/0006-global-hotkeys.md) hotkeys · [0007](adr/0007-trigger-engine-boundary.md) trigger engine · [0008](adr/0008-screenshot-watcher.md) screenshot watcher · [0009](adr/0009-single-source-homes.md) single-source homes · [0010](adr/0010-dependency-allowlist.md) dependency allowlist · [0011](adr/0011-testing-seams.md) testing seams · [0012](adr/0012-project-tooling.md) project tooling
