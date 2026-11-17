# PRD — Flotsam v1.0

**Status:** Draft · 2026-11-16 · Owner: Friday · Constitution: [TRUTHS.md](TRUTHS.md) (outranks this document)

## 1. Primary Truth (verbatim)
> Anything you copied or screenshotted on this Mac in the past 30 days is back in the app you're
> working in within 3 seconds and without touching the mouse, and none of it ever leaves the Mac.

## 2. Problem
macOS keeps one clipboard item. Screenshots land in a folder disconnected from the clipboard. Paid tools
(LinkHiv, Paste) fix this behind license servers or cloud sync; the open tools (Maccy) stop at a text list.
There is no free, local-only app that recalls clips *and* screenshots by what they were, keeps multi-file
copies together, lets you drag them out, and turns favourites into triggers.

## 3. Users
- **Primary — the keyboard-first Mac professional** (developer, writer, designer): copies 50–300 things a
  day, wants yesterday's link back without the mouse, distrusts cloud clipboard tools.
- **Secondary — the visual worker:** lives in screenshots and files; wants to drag them into Slack/Mail/Figma.

## 4. Goals & Success Metrics
| Goal | Metric | Target |
|---|---|---|
| Fast recall (primary) | Hotkey → pasted, for a clip from yesterday | median ≤ 3 s in timed dogfood tasks |
| Never leaves the Mac (primary) | Outbound connections carrying clip content | 0 (verified by network audit) |
| Capture is invisible | CPU while idle-polling | < 1 % avg; memory < 150 MB with 10k items |
| Library opens instantly | Hotkey → panel visible & focused | p95 ≤ 150 ms with 10k items |
| Recall by what it was (S1) | Searches resolved via type/tag/source filter | tracked in dogfood log |
| Triggers don't misfire (S4) | False expansions in Terminal/Safari/Xcode/VS Code | 0 in test matrix |

## 5. Scope — v1.0 Features (each → one or more FRDs)
| # | Feature | Serves | Summary |
|---|---|---|---|
| F1 | Clipboard capture | Primary | Monitor pasteboard; capture text, rich text (RTF/HTML + plain fallback), links, colors, phone, email, images, files, folders; multi-file copy = one **bundle**; record source app; dedupe; honour concealed/transient types and an ignored-apps list. |
| F2 | Screenshot pickup | S2 | Watch the system screenshot location (read from `com.apple.screencapture`), import new screenshots as `screenshot` items. |
| F3 | Library panel | Primary | Global hotkey opens a floating panel over the current app; type-to-search; arrow keys + Return pastes back into the previous app; ⌘1–9 quick paste; rows/grid views; preview (space); sidebar of types, tags, source apps, pinned. |
| F4 | Organize | S1 | Pin, tags (custom, colored), notes, edit text clips, delete, ungroup bundles, filter by type/tag/source app, sort (recent/oldest/most-used/A–Z). |
| F5 | Item shortcuts & triggers | S4 | Per-item global hotkey; per-item typed trigger (e.g. `;sig`) expanded on Space/Tab/Return; variables `{date}`, `{time}`, `{clipboard}` with formats; rich-text triggers keep links. Per-app exclusion. |
| F6 | Shelf | S3 | Optional edge/menu-bar panel showing recent + pinned items; drag clips out to any app; drop files/text in to add them. Off by default after falsifier review; on in v1. |
| F7 | Retention & storage | Primary | Local SQLite + on-disk blobs in Application Support; retention presets (7 d, 30 d default, 90 d, 1 y, forever) with pinned/triggered items exempt; separate image-size budget; "Clear history". Optional capture pause & "capture only on explicit save" (curated mode). |
| F8 | Onboarding, permissions & settings | Primary | First-run: Accessibility permission (paste-back, triggers), screenshot folder access, hotkey choice, launch at login. Settings: General, Shortcuts, Triggers, Privacy (ignored apps), Storage. Menu-bar icon. |
| F0 | Error system | All | Typed errors, user-facing strings in one catalogue, logging via `os.Logger` (no content in logs). |

## 6. Out of Scope (traced to TRUTHS)
| Excluded | Why |
|---|---|
| iCloud / device sync, accounts, servers | Anti-truth 1 — CUT, not deferred |
| Scripted/form/nested snippets, team snippet libraries | Anti-truth 2 |
| Screenshot capture, annotation, recording, OCR | Anti-truth 3 |
| License keys, trials, telemetry, analytics, crash-reporting services | Anti-truth 4 |
| iOS companion, AirDrop/Share from Shelf, themes beyond light/dark, Mac App Store build | NOT DOING (v1) |

## 7. Platform & Distribution
macOS 14 Sonoma+, Apple silicon and Intel. Swift 6 / SwiftUI with AppKit `NSPanel` for the Library and
Shelf. Not sandboxed (Accessibility + CGEvent paste-back). Distributed as a Developer-ID-signed, notarized
DMG on GitHub Releases; Homebrew cask after 1.0. Build from source with Xcode 16+.

## 8. Monetization
None. MIT licensed, free forever, no donations gate any feature (anti-truth 4). Optional GitHub Sponsors link in README only.

## 9. Privacy & Security
- All data in `~/Library/Application Support/Flotsam/`; no network entitlement used for content. The only
  permitted network call is an opt-in update check (Sparkle appcast) that sends no clip data.
- Skip items flagged `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`; default
  ignored apps include common password managers.
- Logs never contain clip content.

## 10. Risks
| Risk | Mitigation |
|---|---|
| Accessibility permission friction | Clear onboarding; Library still works (copy-to-clipboard) without it |
| Trigger misfire / secure input fields | Respect Secure Event Input; per-app exclusion; test matrix (S4 falsifier) |
| Large image history bloats disk | Image budget + "Efficient" downscale preset |
| Polling cost | 0.5 s `changeCount` poll is the proven pattern (Maccy); measure in perf test |
| IP: resemblance to LinkHiv | Workflow only; original name, copy, icon and visual design |

## 11. FRD Index
_Linked after Phase 5._
