# FRD-009 — Distribution

**Status:** Draft · 2026-11-17 · Constitution: [TRUTHS.md](../TRUTHS.md) · PRD: [PRD.md](../PRD.md) §7, §9 · Cut list: [CUT.md](../CUT.md)
**Owns:** the shipped artifact (a DMG), its signing and notarization, version and build numbering, the published checksum, and `bin/release.sh`.
**Does not own:** the Homebrew cask (after 1.0), Sparkle or any updater (DEFER, `CUT.md`), the app's own network behaviour ([FRD-008](FRD-008-OnboardingSettings.md) FR-008-18).

## Truth Test
- Serves: the free, open Primary Truth: anyone can install Flotsam without Xcode or building from source. A1/A4 (no account, no licence, no telemetry) hold: the installer asks for nothing.
- Violates: none. No update check exists, so the zero-network promise is intact; users update by downloading the next DMG.
- Verdict: KEEP.

## 1. Purpose
A person downloads one file from GitHub Releases, drags Flotsam to Applications, and it opens with no Gatekeeper warning.

## 2. Functional Requirements
- **FR-009-01** Artifact. The release is `Flotsam-<version>.dmg` containing `Flotsam.app` and an `Applications` symlink, so install is one drag.
- **FR-009-02** Signing. The app is signed with a Developer ID Application identity, hardened runtime on, secure timestamp, using the committed entitlements file. The DMG is signed with the same identity.
- **FR-009-03** Notarization. The DMG is submitted with `notarytool --wait` and the ticket is stapled, so it opens offline. A rejected submission fails the release.
- **FR-009-04** Credentials. No identity, team ID, Apple ID or password is committed. The identity comes from the keychain (or `FLOTSAM_SIGN_IDENTITY`); notary access only from a `notarytool` keychain profile (`FLOTSAM_NOTARY_PROFILE`, default `flotsam`). No password is accepted from the environment or passed on the command line, where `ps` could read it. A missing or unusable profile is reported as a missing item (FR-009-05) with the exact `store-credentials` command.
- **FR-009-05** Ad-hoc fallback. Without a Developer ID certificate or notary credentials the script still builds an ad-hoc-signed DMG, prints every missing item, and states it is not distributable. It never publishes.
- **FR-009-06** Versioning. `project.yml` is the only home of the version (`CFBundleShortVersionString`) and build (`CFBundleVersion`). A new version resets the build to 1; the build increases only within a version. If either value cannot be read, the release fails before building.
- **FR-009-07** Checksum. `Flotsam-<version>.dmg.sha256` (SHA-256) is produced next to the DMG and uploaded with it. `dist/` holds only the current release: older DMGs and checksums are removed on each run.
- **FR-009-08** No updater. The app target contains no updater and no network code (verified by FRD-008 AC-008-13).
- **FR-009-09** Publishing. Tagging and creating the GitHub Release are manual, by the maintainer, after the script succeeds. The script does neither.
- **FR-009-10** Tools. Only Xcode tools, `hdiutil`, `shasum` and xcodegen (ADR-0012); no new dependency (ADR-0010).
- **FR-009-11** Minimum OS. The app requires macOS 26 or later (Ryan, 2026-11-18; macOS 14 and 15 are not supported). `project.yml` holds the app's deployment target and `LSMinimumSystemVersion` (both `26.0`, kept equal; `Info.plist` is generated from it), and `FlotsamCore` declares the same platform.

## 3. Acceptance Criteria
- **AC-009-01** (FR-009-01) Given a built DMG, when mounted, then it holds exactly `Flotsam.app` and an `Applications` symlink.
- **AC-009-02** (FR-009-02) Given a Developer ID release, `codesign --verify --deep --strict` passes and `codesign -dv` shows the runtime flag and a timestamp.
- **AC-009-03** (FR-009-03) Given a notarized DMG, `xcrun stapler validate` passes and `spctl -a -t open --context context:primary-signature` reports `accepted`, `source=Notarized Developer ID`.
- **AC-009-04** (FR-009-04) `git grep` of the repo finds no team ID, Apple ID, password or signing identity.
- **AC-009-05** (FR-009-05) Given no Developer ID certificate, `bin/release.sh` exits 0 with an ad-hoc DMG, lists the missing certificate and profile, and the app passes `codesign --verify --deep --strict`.
- **AC-009-06** (FR-009-06) The DMG name and the app's `CFBundleShortVersionString` equal the `project.yml` version.
- **AC-009-07** (FR-009-07) `shasum -a 256 -c Flotsam-<version>.dmg.sha256` passes in `dist/`.
- **AC-009-08** (FR-009-08, FR-009-09) The script contains no `git tag`, `gh release` or upload command.
- **AC-009-09** (FR-009-02, FR-009-03) On a clean Mac, opening the downloaded notarized DMG and launching the app from Applications shows no Gatekeeper warning.
- **AC-009-10** (FR-009-11) The built app's `Info.plist` has `LSMinimumSystemVersion` `26.0`, `MACOSX_DEPLOYMENT_TARGET` is `26.0` and `Packages/FlotsamCore/Package.swift` declares `.macOS("26.0")`; no `@available` or `#available` branch names a macOS below 26.
