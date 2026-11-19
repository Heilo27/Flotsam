# ADR-0009: Single-source homes (strings, settings, errors, limits)

Status: Accepted (2026-11-16). Applies Constitutional Rule 9 and FRD-000.

## Context
FRD-000 defines one error registry (`<MOD>-<CAT>-<NNN>`, FR-000-01..07), FRD-008 one settings registry (FR-008-02), FRD-007 the ingest limits and schema. User-facing strings must never be literals at call sites.

## Decision
| Knowledge | One home | Notes |
|---|---|---|
| Error codes, severity, `FlotsamError`, `Result` conventions | `Base/Errors` | Case per code (`.stoIo002`). Severity derived from the code in one `switch`; fatal = STO-IO-002, STO-DB-003 only. A test asserts every case has a catalogue string and a severity. |
| User-facing strings (messages, labels, empty states) | `Base/Resources/Localizable.xcstrings` via `Bundle.module` | Keys `error.<code>`, `ui.<screen>.<name>`. Exposed only through `FlotsamStrings`. No string literal reaches `Text(...)` or an alert except through it. |
| Settings (19 keys, defaults, ranges, validation, change stream) | `Base/Settings` | Typed `SettingKey<Value>`; one validator per key; one `SettingsStore`. No `UserDefaults` access outside `SettingsStore` (grep-enforced). Default chord (S-2), default ignored apps (S-6), default excluded trigger apps live here as registry defaults. |
| Ingest limits (10 MiB text, 5 MiB rich rep, 100 MiB image, 500 bundle members, 2000-char note) | `Storage/IngestLimits`; the bundle member ceiling's number lives in `Base/BundleLimits` and `IngestLimits.maxBundleMembers` re-exposes it | Named constants; Storage reads them through `IngestLimits`. Payload cannot import Storage (ADR-0001), so it reads the bundle ceiling from `BundleLimits`. Nothing restates a number. |
| `ItemKind`, `CapturedPayload`, `Chord`, `SearchNormalizer` | `Base` | Needed by 3+ modules. |
| Classification and `contentKey` | `Payload` | Capture, Shelf drop and screenshot import call it. |
| Screenshot name prefixes | `Screenshots/ScreenshotNamePrefixes` | One list (S-8 fills it). |
| Reserved chords | `Shortcuts/ReservedChords` | One list; the recorder and the registry both ask the same validator. |
| Paste timing windows | `Paste/PasteTiming` | Tuned in one place (ADR-0005). |
| Schema, migrations | `Storage/Migrations` | Only Storage knows table names. |
| Log categories and redaction | `Base/Logging` | `LogSafeValue` admits ids, counts, byte sizes, codes, bundle ids; never text, paths, URLs or keystrokes (A4). |
| Formatters (date, byte size) | `Base/Formatting` | Added with the first user-visible use; none in the skeleton. |

## Consequences
Adding an error code touches `ErrorCode`, the catalogue and FRD-000 in one commit (Rule 7). Adding a setting touches the registry and FRD-008. `bin/check-architecture.sh` grep-checks the two cheapest violations: `UserDefaults` outside `SettingsStore`, and `print(`/`NSLog(` anywhere.

## Alternatives rejected
- **Per-module error enums wrapped in a global one.** Two catalogues to keep in step; FRD-000 is a single registry.
- **String literals with `NSLocalizedString` at call sites.** Allowed in practice, but nothing stops two sites phrasing one error twice.

## Reversibility
High (rename and move).
