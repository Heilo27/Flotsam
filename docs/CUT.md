# CUT — Flotsam

Features cut by the Truth Test (Rule 8). Re-proposing one requires a truth amendment by Ryan.

| Date | Feature | Failed | Reason |
|---|---|---|---|
| 2026-11-16 | iCloud / multi-device sync | Anti-truth 1 | Not a sync service |
| 2026-11-16 | Weekly/lifetime license, trial, device limits | Anti-truth 4 | Free forever, MIT |
| 2026-11-16 | Built-in screenshot capture & annotation | Anti-truth 3 | Recall only |
| 2026-11-16 | OCR search of images | Anti-truth 3 / NOT DOING | ~~Screenshot-tool territory~~ REVERSED 2026-11-19 (Ryan): A3 amended, on-device OCR for search only, v1 |
| 2026-11-16 | Local MCP server / AI-agent access to history | Serves no truth; endangers Primary Truth ("none of it ever leaves the Mac") | CUT: exposing the library to other processes and agents creates an access surface the privacy promise cannot bound. REVERSED 2026-11-19 (Ryan): opt-in, local only, per-client approval, v1. Specified in FRD-010 and ADR-0013 (TASK-553) |
| 2026-11-16 | Apple Intelligence / LLM enrichment of clips (summaries, auto-tags, smart search) | Serves no truth | CUT: recall by type (S1) already covers the need without content handing to a model; adds an OS-version dependency. REVERSED 2026-11-19 (Ryan): v1.1, on-device only |
| 2026-11-16 | Scripted, cursor-position, fill-in-field and date-math text expansions | Anti-truth 2 | CUT: Flotsam is not a text-expander suite; triggers stay literal plus `{date}`, `{time}`, `{clipboard}` (FRD-005) |
| 2026-11-16 | Screen-recording pickup (video import) | Anti-truth 3 | CUT: screenshots are recalled, recordings are screenshot-tool territory |
| 2026-11-16 | Sparkle auto-update / opt-in update check | DEFER: serves no truth in v1.0; v1.0 makes zero network calls (Primary Truth falsifier) | DEFER post-MVP: updates ship as a new signed DMG on GitHub Releases. Revisit after v1.0 only on an explicit Ryan decision about the zero-network promise |
| 2026-11-17 | "Copied, saved" confirmation shown on every capture | Serves no truth | CUT: capture stays silent; a toast on every ⌘C adds noise and nothing to the 3 s recall path. Failures still surface per FRD-000 FR-000-08. REVERSED 2026-11-19 (Ryan): quiet capture cue, can be turned off, v1. Specified in FRD-001 FR-001-30 and FRD-008 FR-008-32 (`capture.cue`, default on; TASK-550) |
