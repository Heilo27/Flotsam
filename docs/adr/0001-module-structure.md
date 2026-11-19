# ADR-0001: Module structure and dependency rules

Status: Accepted (2026-11-16). Load-bearing: flagged to Friday.

## Context
Eight FRDs (001 to 008) plus the error system (000) must share one process without turning into one pile. Forces:
- ARCH-001: dependencies flow down only, no cycles, features never import features, domain has no UI dependencies.
- FR-000-02 and FR-007-02: only one module may import SQLite; no SQLite type crosses its API.
- A4 and FR-000-15: nothing in the app may be able to reach the network. The cheapest guarantee is a small, reviewable import surface.
- Truth P1 (recall in 3 s, nothing leaving the Mac) makes capture, storage and search the stable core; panels, onboarding and Shelf behaviour are the parts most likely to change (spikes S-3 and S-7 can reshape them).
- Several flows are shared and must have one owner (Rule 9): the paste sequence (FR-003-15 is also steps 6 of FR-005-14), payload classification and `contentKey` (Capture, Shelf drop FR-006-13, screenshot import), search normalisation (writer in Storage, query tokens in Library).

## Decision
One local SPM package, `Packages/FlotsamCore`, with eleven library targets in four layers, and one app target `Flotsam` that owns everything that touches the UI or a system adapter.

```
L4  Flotsam (app target)     SwiftUI + AppKit panels, menu bar, Settings, onboarding,
                             platform adapters (NSPasteboard, CGEvent, Carbon, FSEvents, SMAppService),
                             composition root
L3  Capture  Screenshots  Library  Shortcuts  Triggers  Shelf      (features: import L0..L2 only, never each other)
L2  Paste                                                          (services: import L0..L1)
L1  Storage (GRDB)   Payload                                       (no mutual import)
L0  Base                                                           (errors, log, settings registry, seams, shared value types)
```

Import table (the whole graph):

| Target | Imports | Owns (FRs) |
|---|---|---|
| Base | Foundation, os | FRD-000; settings registry (FRD-008 FR-008-02); seam protocols; `ItemKind`, `CapturedPayload`, `Chord`, `SearchNormalizer` |
| Storage | Base, GRDB, ImageIO | FRD-007 (schema, ingest, blobs, image pipeline, query layer, retention, deletion, integrity) |
| Payload | Base, CryptoKit | FRD-001 FR-001-05 to -15 classification, typed-text detection, `contentKey` |
| Paste | Base, Storage | FR-003-15 steps 1 to 6, FR-001-03 own-write markers; FR-005-17 template variables and FR-005-16 clipboard preservation (shared by item hotkeys and triggers, so they sit below both) |
| Capture | Base, Storage, Payload | FRD-001 polling state machine, gates, ignore list, privacy suspension |
| Screenshots | Base, Storage, Payload | FRD-002 |
| Library | Base, Storage, Paste | FRD-003 view-state, FRD-004 organize commands |
| Shortcuts | Base, Storage, Paste | FRD-005 FR-005-01 to -09 (registry, chord rules, recorder logic) |
| Triggers | Base, Storage, Paste | FRD-005 FR-005-10 to -21 (matcher, snapshot, expansion) |
| Shelf | Base, Storage, Payload | FRD-006 reveal state machine, drop processing |
| MCP | Base, Storage | FRD-010 approval gate, line framer, JSON-RPC handler (ADR-0013); the socket server and peer identity are adapters in `App/Platform/` |

Rules (enforced by `bin/check-architecture.sh`, run before every commit and in CI):
1. A target imports only the targets listed above. SwiftPM refuses cycles and undeclared imports at compile time, so the table is the graph, not a convention.
2. No package target imports AppKit, SwiftUI, Carbon, ServiceManagement or ApplicationServices. System access goes through a port protocol in Base (ADR-0011), implemented in `App/Platform/`.
3. Only Storage imports GRDB or SQLite3.
4. No package or app source uses URLSession, NWConnection, NWPathMonitor, WKWebView, CFNetwork, an IP, TCP or UDP socket, or links Sparkle (A4). An `AF_UNIX` socket is not a network API and is allowed (ADR-0013).
5. No `print`, `NSLog`, `dump`, `try!`, or force-unwrap on external data in package sources (FR-000-09, FR-000-02).
6. Language mode is Swift 6 everywhere.

## Alternatives rejected
- **One package target with folders.** Cheapest to start, but ARCH-001 then lives only in review and a grep; the first rushed commit makes Library import Capture. Reversible later but the damage is imports, not files.
- **A Swift package per module (eleven packages).** More ceremony (eleven manifests, version pinning) for no extra enforcement over multi-target.
- **Platform adapters as their own package target.** It would be imported only by the app, so it adds a target and an edge with no consumer. Adapters stay in the app target until a second binary (CLI, helper) needs them.
- **Merging Shortcuts and Triggers.** They share FRD-005 but not mechanism: Carbon registration needs no permission and never runs on a tap thread; the matcher is thread-confined and needs both permissions. Separate failure modes, separate targets.

## Consequences
- Adding a feature means a new target and an edge in this table; an edge from one feature to another is a design error, fix by moving the shared piece down (as Payload and Paste already are).
- Ten manifests entries are verbose but cheap; feature targets are mostly thin state machines over Storage and ports.
- UI is tested only through the app target; everything under it is testable with `swift test` and no UI.

## Reversibility
High. Collapsing targets is a file move. Splitting a target later costs import cleanup, which is why the split is made now.
