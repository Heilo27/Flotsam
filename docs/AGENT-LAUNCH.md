# Launching an isolated Flotsam (agents and automation)

A Debug build can run without touching your real Flotsam data, settings or Keychain item. Release builds ignore everything
on this page: the variables, the parser and the fakes are compiled out (`#if DEBUG`).

## Build

```sh
bin/build.sh        # Debug build into ./build (unsigned)
```

The binary is `build/Build/Products/Debug/Flotsam.app/Contents/MacOS/Flotsam`.

## Launch

Run the binary directly, never `open Flotsam.app`: LaunchServices would hand the request to a Flotsam that is already
running (the real one, if you use it) and your variables would never be read. Use a fresh folder and a fresh suite name
per run.

```sh
DIR="$(mktemp -d)/flotsam-data"
SUITE="flotsam-agent-$(date +%s)"
# Optional, before launch: keep the screenshot folder and the typed-trigger tap out of the run (see "Still shared").
defaults write "$SUITE" screenshots.enabled -string false
defaults write "$SUITE" triggers.enabled -string false

FLOTSAM_DATA_DIR="$DIR" FLOTSAM_DEFAULTS_SUITE="$SUITE" FLOTSAM_FAKE_SECURE=1 \
  build/Build/Products/Debug/Flotsam.app/Contents/MacOS/Flotsam &
PID=$!
# ... drive and observe ...
kill "$PID"                                  # only your own PID
defaults delete "$SUITE"; rm -rf "$DIR"
```

## Variables

| Variable | Effect |
| --- | --- |
| `FLOTSAM_DATA_DIR` | Absolute path used as the data folder itself (database, `blobs/`, `thumbs/`, `tmp/`). Not `~`-expanded. The real folder is refused. |
| `FLOTSAM_DEFAULTS_SUITE` | A separate defaults domain (`~/Library/Preferences/<suite>.plist`) for every setting and the onboarding resume point. Not the app's own bundle id. |
| `FLOTSAM_FAKE_SECURE=1` | Secure (concealed) items use an in-memory key and a scripted authenticator: no Keychain call, no Touch ID or password prompt. The key dies with the process, so secure items sealed in one run cannot be opened in the next. `0` or unset leaves it off. |
| `FLOTSAM_FAKE_AUTH` | With `FLOTSAM_FAKE_SECURE=1`: `allow` (default) confirms every secure paste, `deny` fails each one with `LIB-OS-002`. Ignored without the fake. |

A variable that is set but unusable (relative path, empty value, `FLOTSAM_FAKE_SECURE=yes`, the real data folder) makes
the app print the reason on stderr and exit 64. It never falls back to the real data.

With none of the variables set, a Debug build behaves exactly as a Release build does.

The one home of this logic is `LaunchIsolation` (`Packages/FlotsamCore/Sources/FlotsamBase/Launch/`); the app resolves it
once in `App/Flotsam/AppEnvironment.swift`. A source-scan test (`LaunchIsolationTests`) fails if a `UserDefaults`,
Application Support, Keychain or LocalAuthentication use appears anywhere else.

## Still shared with the real machine

Isolation covers the data folder, the settings domain and the secure store. An isolated instance still:

- **Reads the real pasteboard** and copies whatever is on it into the isolated database. Anything you copy while it runs
  is stored in `FLOTSAM_DATA_DIR`. Paste-back writes to the real pasteboard and posts keystrokes to the frontmost app.
- **Registers the same global hotkeys** (Carbon). If a real Flotsam is running, its hotkeys win or the registration
  fails; do not run both when testing hotkeys. Not isolated by design.
- **Watches the real screenshot folder** (`com.apple.screencapture` location, else the Desktop) when
  `screenshots.enabled` is on (default on), and imports recent screenshots into the isolated database. First read of a
  protected folder can raise a TCC prompt. Pre-seed `screenshots.enabled` to `false` as above to avoid it.
- **Installs the typed-trigger event tap** when `triggers.enabled` is on (default on) and the Mac has granted it.
  Pre-seed it to `false` to skip. Not isolated by design.
- **Uses the same Accessibility and Input Monitoring grants.** TCC keys them to the signed binary and its path, so a
  Debug build in `build/` is its own entry; the prompt (`AXIsProcessTrustedWithOptions`) fires only when an onboarding
  or Settings button asks for it, never at launch. Do not click it from automation.
- **Registers the login item** only when the user toggles it (Settings or onboarding), never at launch. Do not toggle it
  in an isolated run: `SMAppService.mainApp` is one registration per app bundle, not per data folder.
- **Reads `com.apple.screencapture`** (read-only) and the frontmost-app and source-app information of the live session.
- **AppKit's own autosaved UI state** (for example the menu-bar item position) is keyed by the app's bundle id, not by
  Flotsam, so it cannot be pointed at the suite. A 12-second isolated launch with the screenshot watcher and typed
  triggers off left the real defaults domain, its preferences file and the real data folder byte-for-byte unchanged,
  but a longer session or a moved window could write there. Compare the real domain before and after if it matters.
- **Shows the first-launch onboarding window**, because the fresh suite has no resume point.

## Release check

A Release build must contain none of this:

```sh
xcodebuild -project Flotsam.xcodeproj -scheme Flotsam -configuration Release -derivedDataPath build/release \
  CODE_SIGNING_ALLOWED=NO build
strings build/release/Build/Products/Release/Flotsam.app/Contents/MacOS/Flotsam | grep -E "FLOTSAM_(DATA_DIR|DEFAULTS|FAKE)" \
  && echo "LEAK" || echo "clean"
```
