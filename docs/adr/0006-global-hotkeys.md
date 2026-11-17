# ADR-0006: Global hotkeys, in-house Carbon wrapper

Status: Accepted; spike S-5 (TASK-008) pending, S-2 (TASK-005) affects only the default chord.

## Context
FR-005-03 requires Carbon `RegisterEventHotKey` (no Accessibility, no Input Monitoring). FR-005-04 requires every global hotkey to be unregistered while any recorder is recording. FR-005-01 and FR-005-22: up to roughly 100 per-item hotkeys that appear and vanish with item edits and deletes in the same transaction. FR-005-02 rejects ⌥-only and ⌥⇧-only chords. Settings are in one registry (FRD-008 FR-008-02).

## Decision
Write a thin Carbon wrapper: `HotkeyRegistrar` port in Base; the Carbon adapter (`CarbonHotkeyRegistrar`, about 150 lines) in `App/Platform/`; chord model, validation (FR-005-02 a to d, reserved list) and the registry (which hotkeys exist, which fail, retry on launch, wake and re-save) in `Shortcuts`. Do not depend on the KeyboardShortcuts package.

## Alternatives rejected
- **KeyboardShortcuts (MIT).** It owns the recorder UI, its own `UserDefaults` storage (a second settings home, against FR-008-02 and Rule 9), and a name-based API, whereas our per-item hotkeys are dynamic and keyed by item id. It does not give "unregister all while recording" or our validation rules; we would wrap it enough to lose the benefit. It also adds a dependency to an app whose trust story is a tiny import surface.
- **NSEvent global monitor for key events.** Needs Input Monitoring; wrong tool for hotkeys.

## Consequences
We own Carbon quirks (`kEventHotKeyPressed` handler, `EventHotKeyID` mapping, modifier translation). The adapter is isolated behind the port, so a failed assumption from S-5 (for example Carbon registration requiring a permission on some OS) changes FR-008-14's "hotkeys keep working" line and the adapter only.

## Reversibility
High.
