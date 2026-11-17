# Flotsam — Friday Context

## What This Is
Free, MIT, local-first macOS clipboard + screenshot history (Library, Shelf, tags, bundles, triggers) — an open alternative to the paid LinkHiv workflow.

## Stack
Swift 6 · SwiftUI + AppKit (NSPanel) · SQLite (decided in architecture) · macOS 14+ · direct distribution (signed DMG on GitHub Releases), not Mac App Store.

## Critical Rules
- PUBLIC repo (github.com/Heilo27/Flotsam). Never commit secrets, signing identities, team IDs in plain config, or anything from LinkHiv (name, copy, art, screenshots). We reimplement the workflow, never the expression.
- No network code that carries clip content. No telemetry, accounts, license keys (anti-truths A1, A4).
- Not sandboxed: paste-back and triggers need Accessibility; screenshot pickup needs folder access.
- Respect `org.nspasteboard.ConcealedType` / `TransientType` and ignored apps — never store password-manager copies.
- docs/TRUTHS.md outranks the PRD; FRDs move with code in the same commit.

## Project State
2026-11-16: Phases 0–4 done (truths confirmed, repo public, PRD). FRDs done. Phase 6 design done: docs/DESIGN.md + docs/design/ (HTML mockups; Pencil was unavailable).

## Ticketmaster ID
`flotsam`
