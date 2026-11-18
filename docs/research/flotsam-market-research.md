# Market Research — Flotsam (2026-11-16)

**Feasibility: GREEN.** Every capability uses public macOS APIs (NSPasteboard polling, FSEvents on the
screenshot folder, Accessibility/CGEvent for paste-back and trigger expansion). Open-source precedent
(Maccy) proves the core; the gap is the organization + screenshot + drag + trigger layer, which today
exists only in paid apps.

| App | Strengths | Weaknesses | Price | Open? |
|---|---|---|---|---|
| LinkHiv | Library + "Clipboard Island" drag shelf, screenshot-folder pickup, tags/notes, bundles, text expander w/ date/time/clipboard vars, persistent item shortcuts, source-app filter | Closed, paid, license server + device limits | US$79 lifetime / weekly sub | No |
| Maccy | Fast keyboard history, tiny, mature (~14.5k★) | No tags/notes, screenshots, bundles, shelf or triggers | Free (App Store $9.99) | MIT |
| Paste | Polished strip UI, pinboards, iCloud sync | Subscription, cloud | ~$30/yr | No |
| Raycast clipboard | Launcher-integrated, OCR | Clipboard is a side feature; no tags/screenshot pickup | Free / Pro sub | No |
| Spotlight (macOS 26) | Built-in ⌘Space ⌘4 history | Short history, no organization | Free | No |
| OpenPaste / Pesty / PasteMemo / Clipbara | Various open SwiftUI managers | None combine screenshots + shelf + triggers | Free | MIT/GPL |

**Platform:** macOS 26+, native Swift/SwiftUI + AppKit panels; direct distribution (signed/notarized DMG
on GitHub Releases, Homebrew cask). Mac App Store excluded: sandbox blocks paste-back and global key
monitoring for triggers.

**Opportunity:** The LinkHiv workflow — recall by type/tag/source, screenshots in the same history, a drag
shelf, and triggers — has no open-source implementation. A local-only, MIT build fills that gap for
privacy-minded users who won't run a license-checking, cloud-adjacent clipboard tool.

Source material: linkhiv.com marketing copy (sitemap + JS bundle), extracted to `.claude/scratch/linkhiv-copy.txt` (not committed).
