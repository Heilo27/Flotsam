# ADR-0010: Dependency allowlist

Status: Accepted (2026-11-16).

## Context
Flotsam is MIT, free, public, zero-network in v1.0, and its trust story is a small, auditable import surface (TRUTHS, PRD). Every dependency is code that reads the user's clipboard history.

## Decision
Allowed third-party dependencies, in total: **GRDB.swift** (MIT) in `Storage` only.

Rules for any addition (requires an ADR amendment before merge):
1. License MIT, BSD, Apache-2.0 or ISC; compatible with a signed, notarised, MIT-licensed DMG.
2. No network capability, no telemetry, no analytics.
3. Pinned `exact` in `Package.swift`; `Package.resolved` committed; the version bump is a reviewed diff.
4. Imported by one module, stated in the ADR; never by the UI layer directly.
5. Would take more than about 300 lines to write and own correctly (GRDB passes; a hotkey wrapper and a launch-at-login call do not).

Rejected now: KeyboardShortcuts (ADR-0006), Sparkle (deferred in `docs/CUT.md`: network updates break the zero-network claim), LaunchAtLogin (call `SMAppService.mainApp` directly, about 20 lines in the app target), Defaults (a second settings layer, ADR-0009), SwiftLint (not a runtime dependency but a build plugin that executes third-party code; the checks we need are greps in `bin/check-architecture.sh`).

## Consequences
CI and `bin/check-architecture.sh` fail if `Package.swift` or `project.yml` names a package outside this list and the ADR has not been amended.

## Reversibility
High.
