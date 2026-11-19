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

Requires macOS 26+. MIT licensed.

## Privacy
Flotsam keeps your history in a folder on your Mac and sends it nowhere. Deleting a clip removes it from that history, but Flotsam keeps two kinds of safety copy of its database for a while, and a clip you deleted can still be inside one:
- **Upgrade backup.** When an update changes how the database is stored, Flotsam first copies the database. It deletes that copy the next time you open Flotsam and the upgraded database opens and checks out healthy, usually within hours. If that launch fails, or Flotsam quits before it, the copy stays until a launch succeeds.
- **Damaged-database copy.** If the database is found damaged, Flotsam moves it aside so you can recover from it, starts a new empty history, and keeps the moved-aside copy for 30 days, then deletes it. While one of these copies exists, the upgrade backup is kept too, because it may be the last good version of your history.

**Password-manager copies.** A copy a password manager marks as concealed is kept, but only as an encrypted item: its text is sealed with a key held in your Mac's Keychain, it shows as dots with its source app, and copying it again needs your Mac password or Touch ID. It follows your history period like any other clip. Because Flotsam keeps its own encrypted copy, the password manager's auto-clear no longer limits how long it exists; delete the item, or add the manager to Settings > Privacy > Ignored apps to have its copies dropped instead.

**Clear History** deletes both kinds of copy at once. Both live in Flotsam's data folder, readable only by your account.

## Download and install
Get `Flotsam-<version>.dmg` from [GitHub Releases](https://github.com/Heilo27/Flotsam/releases), open it, drag Flotsam to Applications, launch it. Check the download with `shasum -a 256 -c Flotsam-<version>.dmg.sha256`. Updates are a new DMG; Flotsam never phones home.

## Release (maintainers)
`bin/release.sh` builds, signs, notarizes, staples and checksums into `dist/` ([FRD-009](docs/frd/FRD-009-Distribution.md)). Bump the version in `project.yml` first (build resets to 1). One-time setup:
1. Create a *Developer ID Application* certificate (Xcode > Settings > Accounts > Manage Certificates).
2. `xcrun notarytool store-credentials flotsam` (prompts for your Apple ID, an app-specific password from account.apple.com, and your team ID).

Or set `FLOTSAM_SIGN_IDENTITY`, or `FLOTSAM_NOTARY_PROFILE` (keychain profile only; passwords are never read from the environment). Without them the script makes an ad-hoc DMG for local testing and lists what is missing. Tagging and uploading to Releases is manual.
