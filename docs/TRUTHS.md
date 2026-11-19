# TRUTHS — Flotsam

Open-source, local-first macOS clipboard + screenshot history. Functional reference: LinkHiv
(linkhiv.com, closed, US$79). We match its form factor (layout, placement, sizing, interaction model) and reach functional
parity or better, reverse-engineered by black-box observation only: no source, no assets. We never
take its name, copy, icon, art or visual skin. A reference feature that adds value and breaks no
truth below is in scope, even if an earlier Truth Test cut it.

## PRIMARY TRUTH
**Anything you copied or screenshotted on this Mac in the past 30 days is back in the app you're
working in within 3 seconds and without touching the mouse, and none of it ever leaves the Mac.**

Falsifier: a timed task ("paste the link you copied yesterday") takes a median >3 s from hotkey to
pasted, OR any feature requires a network call carrying clip content. Either → amend or fix.

## SECONDARY TRUTHS
1. **Recall by what it was, not when** — type detection (link, color, phone, email, file, folder,
   image, screenshot, rich text), source-app filter, tags and notes, so you find a clip you can only
   half-describe. *Serves primary: shortens the 3 s path when you don't remember the time.*
   Falsifier: users search by scrolling more than by type/tag/source in usage tests.
2. **Groups survive** — a multi-file copy stays one bundle; screenshots from the system folder join
   history automatically. *Serves primary: the thing you need was never a clipboard event, or was
   several at once.* Falsifier: bundles are routinely split before reuse.
3. **Drag is a first-class path** — an optional edge Shelf (our "Island") to drag clips out and drop
   files in. *Serves primary for mouse-in-hand moments; keyboard Library stays the main path.*
   Falsifier: Shelf usage near zero after a month of dogfooding → demote to off-by-default.
4. **Repeat text costs one trigger** — saved clips can carry a hotkey or a typed trigger (`;sig` +
   Space/Tab/Return) with date/time/clipboard variables. *Serves primary: the most-recalled clips
   become zero-search.* Falsifier: triggers misfire in common apps (terminal, browser, IDE).

5. **Invisible on the machine** — Flotsam runs all day in the background, so it costs almost
   nothing while you're not using it, and the code stays pithy: when two approaches both work, the
   one with less CPU, memory, wake-ups, disk writes or code wins. Idle means no panel open: the only
   recurring work is the pasteboard `changeCount` poll and the hourly maintenance pass, and memory
   built for a panel (thumbnails, row caches) is released when it closes. *Serves primary: a
   history you'd switch off for its cost recalls nothing.*
   Falsifier: idle over 10 min averages > 0.2 % of one core, > 2.5 wake-ups/s, or > 60 MB physical footprint
   (`phys_footprint`, as reported by `footprint`) with 10,000 items; or the panel open exceeds 150 MB physical footprint.

## ANTI-TRUTHS
1. **Not a sync service.** No iCloud, no account, no server. Paste owns cross-device. A sync request
   is CUT, not deferred.
2. **Not a text-expander suite.** No scripts, forms, nested snippets or team libraries — Typinator
   and Espanso own that.
3. **Not a screenshot tool.** No capture, annotation or recording — CleanShot/Shottr own that. We
   only *recall* screenshots. On-device text recognition (Apple Vision) is allowed solely to make
   images searchable; no OCR editing or export features.
4. **Not a commercial product.** No license keys, trials, telemetry or analytics. MIT, free, forever.

## NOT DOING (v1)
iOS/iPad companion · themes beyond light/dark · Mac App Store build (sandbox breaks paste-back &
accessibility). v1.1: Apple Intelligence actions (on-device only) · per-app clip lifetime rules.

## AMENDMENT LOG
| Date | Change | Reason | FRDs re-tested |
|---|---|---|---|
| 2026-11-16 | Initial truths; primary confirmed by Ryan | — | — |
| 2026-11-17 | Added S5 "Invisible on the machine" (resource budget, pithy code) | Ryan: runs constantly; must be light on resources, most efficient method wins | all FRDs re-tested in TASK-373 (docs/research/S5-resource-audit.md): CPU and idle memory held; wake-ups are 2.0/s for the poll alone and 2.7 to 2.9/s with the watchdog and re-resolve as separate timers (over 2.5); FR-001-20, AC-001-01/16, FR-003-13, FR-007-07 edited; periodic-timer consolidation and Paused-timer changes ticketed |
| 2026-11-18 | Minimum macOS raised from 14 to 26 (macOS 14 and 15 dropped) | Ryan, 2026-11-18: skip macOS 14/15 test environments; ship macOS 26+ only | all FRDs re-read under TASK-487: meaning changes in FRD-001 FR-001-18 (pasteboard gate now unconditional), FRD-008 FR-008-12/13 and §7 tables (onboarding step 2 and the Privacy row always shown), FRD-005 FR-005-02 rationale; assumption rows narrowed to macOS 26 in FRD-003, 005, 006, 007, 008 (spikes S-2, S-3, S-5, S-9 lose their 14/15 matrix rows); FRD-009 FR-009-11 added; FRD-002, 004, 000 unchanged |
| 2026-11-19 | Reference clause: form factor and functional parity (or better) with LinkHiv, by black-box reverse engineering; visual skin stays original | Ryan, 2026-11-19: "it needs to have a form factor that is similar, and functional parity, or even better operation. this is a true reverse engineer cause we dont have any access to its source material" | parity dossier + gap matrix against every FRD under TASK-532 |
| 2026-11-19 | Precedence: reference features that add value and break no truth override earlier CUTs. A3 narrowed: on-device OCR allowed for search only. NOT DOING: Shelf share zone and OCR moved into v1; Apple Intelligence and per-app lifetime rules set for v1.1. Local MCP allowed as opt-in, per-client approval: Flotsam makes no network call itself, and consent warns that a client may send clips to its cloud | Ryan, 2026-11-19, parity ESCALATE rulings: "If the feature adds value, and does not mess up our goals then add them"; edge bar keep if cheap; capture cue keep; per-app lifetime v1.1; share zone v1; OCR search only; Apple Intelligence v1.1; MCP opt-in local only | FRD-000..009 re-read under TASK-548: one stale non-goal edited (FRD-007 §10, per-app lifetime now v1.1); every other conflict (OCR in FRD-001/002/003/007, Shelf search and share-sheet in FRD-006, zero-network text in FRD-008/009, Library AirDrop in FRD-003, edge bar, capture cue, top-centre Shelf, compact Library) is owned by TASK-533/534/535/549/550/551/552/553 and noted there; FRD-004, 005 unchanged |
