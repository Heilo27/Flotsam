# ADR-0012: Project tooling, xcodegen

Status: Accepted (2026-11-16).

## Context
The app target needs an Xcode project (signed DMG, Info.plist, entitlements). The repo is public and will take contributions. A checked-in `.xcodeproj` produces `project.pbxproj` merge conflicts on every added file and is a second description of the target layout beside `Package.swift` (Rule 9). The build must work from the CLI with `-derivedDataPath build/`.

## Decision
`project.yml` (xcodegen) is the single description of the app target. The generated `Flotsam.xcodeproj` is gitignored. `bin/bootstrap.sh` checks for xcodegen (`brew install xcodegen`), regenerates the project and resolves packages. The package `Packages/FlotsamCore` is a local SPM dependency of the app and is the source of truth for library targets.

Build:
```
bin/bootstrap.sh
xcodebuild -project Flotsam.xcodeproj -scheme Flotsam -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
swift test --package-path Packages/FlotsamCore
bin/check-architecture.sh
```
No team ID, signing identity or provisioning data is committed; release signing is injected by the release process outside the repo.

## Alternatives rejected
- **Checked-in `.xcodeproj`.** Works, one fewer tool, but conflicts and drift. Chosen against; reversible by committing the generated project.
- **Pure SwiftPM executable.** No Info.plist/LSUIElement/entitlements/asset catalogue story and no signed `.app` without extra scripting.
- **Tuist.** Heavier than the one target we have.

## Consequences
Contributors need xcodegen (Homebrew, MIT). Mitigated by `bin/bootstrap.sh` and a README line.

## Reversibility
High: run xcodegen once, remove `*.xcodeproj` from `.gitignore`, commit.
