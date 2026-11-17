# Flotsam

Free, open-source clipboard and screenshot history for macOS. Local-first: nothing you copy ever leaves your Mac.

> Status: in development. Specs live in [`docs/`](docs/).

## What it does (v1 scope)
- **Library** — one hotkey opens a searchable history of everything you copied: text, rich text, links, colors, images, files, folders.
- **Screenshot pickup** — new captures in your screenshot folder join history automatically.
- **Recall by what it was** — type detection, source-app filter, tags and notes.
- **Bundles** — copy several files at once and they stay one item.
- **Shelf** — an optional edge panel for dragging clips out and dropping files in.
- **Triggers** — give saved text a hotkey or a typed trigger like `;sig`, with date/time/clipboard variables.

## What it is not
No sync, no accounts, no telemetry, no license keys. See [`docs/TRUTHS.md`](docs/TRUTHS.md).

Requires macOS 14+. MIT licensed.

## Download and install
Get `Flotsam-<version>.dmg` from [GitHub Releases](https://github.com/Heilo27/Flotsam/releases), open it, drag Flotsam to Applications, launch it. Check the download with `shasum -a 256 -c Flotsam-<version>.dmg.sha256`. Updates are a new DMG; Flotsam never phones home.

## Release (maintainers)
`bin/release.sh` builds, signs, notarizes, staples and checksums into `dist/` ([FRD-009](docs/frd/FRD-009-Distribution.md)). Bump the version in `project.yml` first (build resets to 1). One-time setup:
1. Create a *Developer ID Application* certificate (Xcode > Settings > Accounts > Manage Certificates).
2. `xcrun notarytool store-credentials flotsam` (prompts for your Apple ID, an app-specific password from account.apple.com, and your team ID).

Or set `FLOTSAM_SIGN_IDENTITY`, `FLOTSAM_NOTARY_PROFILE`, or `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD`. Without them the script makes an ad-hoc DMG for local testing and lists what is missing. Tagging and uploading to Releases is manual.
