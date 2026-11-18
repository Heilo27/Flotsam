# ADR-0007: Trigger engine boundary

Status: Accepted; spike S-9 (TASK-012) pending (which permissions the active tap really needs).

## Context
FR-005-11 to -21: an active session `CGEventTap` on its own thread, a 24-character word buffer in memory only, boundary-key consumption, suppression under Secure Event Input, IME composition and excluded apps, a health watchdog, p99 ≤ 1 ms per event, keystroke content never persisted or logged (FR-005-20, A4).

## Decision
Split mechanism from policy.
- **Adapter** (`App/Platform/EventTapKeySource`): owns the `CGEventTap`, its thread and run loop, the tap-disabled re-enable, and conversion of `CGEvent` to a small `KeyEvent` value (key code, flags, unicode string, source pid, auto-repeat). It calls `handler(KeyEvent) -> KeyDecision` synchronously in the callback and does nothing else. It implements the `KeyEventSource` port.
- **Matcher** (`Triggers.TriggerMatcher`): a plain, non-`Sendable` struct/class confined to the tap thread; implements FR-005-11/-12/-13 (buffer, boundaries, resets, dead words, exclusion, Secure Event Input and IME flags supplied by ports) and returns `pass`, `consume`, or `consumeAndExpand(itemId)`. No I/O, no logging of content, no allocation beyond the 24-character buffer.
- **Snapshot**: the trigger table (`trigger string -> itemId`) is an immutable value replaced atomically by `itemsDeleted`/edit events (FR-005-22); the matcher reads it under a lock held for microseconds.
- **Expander** (`Triggers.TriggerExpander`): runs off the tap thread per FR-005-14; its ⌘V step is `PasteService` (ADR-0005).
- **Watchdog** (`Triggers.TapHealth`): periodic check (every 10th tick of the shared poll timer, ADR-0004) through `KeyEventSource.isHealthy`, raising `TRG-OS-003` per FR-005-19.

## Alternatives rejected
- **Matcher in the tap adapter.** Untestable without system permissions and a keyboard; the policy is the part with the 30-odd ACs.
- **Listen-only tap plus synthetic backspaces.** Cannot consume the boundary key (FR-005-12), which is a product decision.

## Consequences
Matcher tests are plain unit tests with scripted `KeyEvent` arrays. The adapter is covered by manual and driven tests. Because the adapter is the only code that sees raw keystrokes, the privacy audit (FR-005-20) is a review of ~200 lines.

## Reversibility
High. If S-9 shows Input Monitoring is not needed, only the `PermissionProbe` requirements change.
