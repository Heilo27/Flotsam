# TRUTHS — Flotsam

Open-source, local-first macOS clipboard + screenshot history. Functional reference: LinkHiv
(linkhiv.com, closed, US$79). We match its workflow, not its name, copy, art or look.

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

## ANTI-TRUTHS
1. **Not a sync service.** No iCloud, no account, no server. Paste owns cross-device. A sync request
   is CUT, not deferred.
2. **Not a text-expander suite.** No scripts, forms, nested snippets or team libraries — Typinator
   and Espanso own that.
3. **Not a screenshot tool.** No capture, annotation, recording or OCR search — CleanShot/Shottr own
   that. We only *recall* screenshots.
4. **Not a commercial product.** No license keys, trials, telemetry or analytics. MIT, free, forever.

## NOT DOING (v1)
iOS/iPad companion · AirDrop/Share-sheet from the Shelf (v1.1 candidate) · OCR · themes beyond
light/dark · Mac App Store build (sandbox breaks paste-back & accessibility).

## AMENDMENT LOG
| Date | Change | Reason | FRDs re-tested |
|---|---|---|---|
| 2026-11-16 | Initial truths; primary confirmed by Ryan | — | — |
