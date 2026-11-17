#!/usr/bin/env bash
# Enforces ADR-0001 / ADR-0009 / ADR-0010 rules that a compiler cannot. Exit 1 on any violation.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=Packages/FlotsamCore/Sources
failures=0
# fail MESSAGE [HITS]: with HITS (grep output, one hit per line) every hit counts as one violation; without, the call counts as one.
fail() {
  local n=1
  if [ -n "${2:-}" ]; then echo "ARCH VIOLATION: $1: $2"; n=$(printf "%s\n" "$2" | grep -c .); else echo "ARCH VIOLATION: $1"; fi
  failures=$((failures + n))
}

# Return the import lines of one target as "file:module".
imports_of() { grep -rhoE '^(@testable )?import [A-Za-z0-9_]+' "$SRC/$1" 2>/dev/null | awk '{print $NF}' | sort -u; }

# Allowed imports per target (ADR-0001 table). Portable to bash 3.2 (macOS default): no associative arrays.
allowed_for() {
  case "$1" in
    FlotsamBase) echo "Foundation os" ;;
    FlotsamStorage) echo "Foundation FlotsamBase GRDB" ;;
    FlotsamPayload) echo "Foundation FlotsamBase" ;;
    FlotsamPaste) echo "Foundation FlotsamBase FlotsamStorage" ;;
    FlotsamCapture|FlotsamScreenshots|FlotsamShelf) echo "Foundation FlotsamBase FlotsamStorage FlotsamPayload" ;;
    FlotsamLibrary|FlotsamShortcuts|FlotsamTriggers) echo "Foundation FlotsamBase FlotsamStorage FlotsamPaste" ;;
    *) echo "" ;;
  esac
}
for dir in "$SRC"/Flotsam*; do
  target=$(basename "$dir")
  allowed=$(allowed_for "$target")
  [ -z "$allowed" ] && { fail "unknown target $target: add it to allowed_for and ADR-0001"; continue; }
  for module in $(imports_of "$target"); do
    case " $allowed " in *" $module "*) ;; *) fail "$target imports $module (allowed: $allowed)";; esac
  done
done

# Only Storage may touch GRDB or SQLite.
hits=$(grep -rlE 'import (GRDB|SQLite3)' "$SRC" | grep -v "$SRC/FlotsamStorage/")
[ -n "$hits" ] && fail "GRDB/SQLite3 imported outside Storage" "$hits"

# Zero network in v1.0.
hits=$(grep -rnE 'URLSession|NWConnection|NWPathMonitor|WKWebView|CFNetwork|Sparkle' "$SRC" App 2>/dev/null)
[ -n "$hits" ] && fail "network API referenced" "$hits"

# No print/NSLog/dump; no try! (FR-000-02).
hits=$(grep -rnE '(^|[^A-Za-z_.])(print|NSLog|dump)\(|try!' "$SRC" App 2>/dev/null)
[ -n "$hits" ] && fail "print/NSLog/dump/try! used" "$hits"

# FR-000-02 / AC-000-01: no thrown errors across a module boundary, no force-cast, no force-unwrap, and
# fatalError only where it is annotated. Comment lines are ignored so doc comments can name the banned APIs.
NOT_COMMENT='^[^:]+:[0-9]+:[[:space:]]*//'
hits=$(grep -rnE '(public|package|open)[^{=]* throws' "$SRC" App --include='*.swift' 2>/dev/null | grep -vE "$NOT_COMMENT" | grep -v 'Ports/Ports.swift')
[ -n "$hits" ] && fail "public/package API declared 'throws' (return FlotsamResult; only WallClock.sleep may throw, for cancellation)" "$hits"
hits=$(grep -rnE '[[:space:](]as!' "$SRC" App --include='*.swift' 2>/dev/null | grep -vE "$NOT_COMMENT")
[ -n "$hits" ] && fail "force cast (as!) used" "$hits"
hits=$(grep -rnE '[A-Za-z0-9_)]!([.,)]|[[:space:]]*$)' "$SRC" App --include='*.swift' 2>/dev/null | grep -vE "$NOT_COMMENT")
[ -n "$hits" ] && fail "force unwrap (!) used" "$hits"
# Only the two Fatal codes (FR-000-04) and unreachable programmer-error invariants may stop the process; the latter
# must say why on the same line with 'fatal-ok:'.
hits=$(grep -rnE '(fatalError|preconditionFailure|precondition)\(' "$SRC" App --include='*.swift' 2>/dev/null | grep -vE "$NOT_COMMENT" | grep -v 'fatal-ok:')
[ -n "$hits" ] && fail "fatalError/precondition without a 'fatal-ok: <reason>' annotation" "$hits"
# localizedDescription can embed file paths (FR-000-01, FR-000-10); UnderlyingErrorInfo is the only way to carry a cause.
hits=$(grep -rn 'localizedDescription' "$SRC" App --include='*.swift' 2>/dev/null | grep -vE "$NOT_COMMENT")
[ -n "$hits" ] && fail "localizedDescription used (use UnderlyingErrorInfo)" "$hits"

# FR-000-05: the String Catalog is the only home for user-facing text. A literal handed to a view or an AppKit text
# property bypasses it (and the 140-character and interpolation checks), so it fails the build. Heuristic by design:
# it catches the common SwiftUI and AppKit entry points; code review and the catalogue test cover the rest.
hits=$(grep -rnE '(Text|Button|Label|Toggle|Picker|Section|TextField|SecureField|Menu|Link|MenuBarExtra|Stepper|GroupBox|DisclosureGroup)\("|\.(help|navigationTitle|accessibilityLabel|accessibilityHint|badge|confirmationDialog|alert)\("|\.(messageText|informativeText|title|stringValue|toolTip|placeholderString|label) = "|withTitle: "' "$SRC" App --include='*.swift' 2>/dev/null | grep -vE "$NOT_COMMENT")
[ -n "$hits" ] && fail "user-facing string literal outside the catalogue (use FlotsamStrings.text(forKey:))" "$hits"
# Catalogue keys are 'error.<code>' or 'ui.<screen>.<name>' (FR-000-05).
CATALOGUE="$SRC/FlotsamBase/Resources/Localizable.xcstrings"
hits=$(grep -E '^    "[^"]+" : \{' "$CATALOGUE" | sed -E 's/^    "([^"]+)".*/\1/' | grep -vE '^(error\.[A-Z]{3}-[A-Z]{2,3}-[0-9]{3}|ui\.[a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*)$')
[ -n "$hits" ] && fail "catalogue key does not match error.<code> or ui.<screen>.<name>" "$hits"

# UserDefaults only behind SettingsStore adapters (ADR-0009): Base/Ports/Adapters.swift is the single adapter.
hits=$(grep -rn 'UserDefaults' "$SRC" App 2>/dev/null | grep -v 'Ports/Adapters.swift')
[ -n "$hits" ] && fail "UserDefaults used outside Ports/Adapters.swift" "$hits"

# FR-000-09: one logging entry point. Logger, os_log and .debug( live only in Logging/FlotsamLog.swift, so categories,
# levels and the privacy policy (FR-000-10) cannot be bypassed by a call site that builds its own Logger.
hits=$(grep -rnE '\bLogger\(|os_log\(|\.debug\(' "$SRC" App --include='*.swift' 2>/dev/null | grep -vE "$NOT_COMMENT" | grep -v 'FlotsamBase/Logging/FlotsamLog.swift')
[ -n "$hits" ] && fail "Logger/os_log/.debug used outside Logging/FlotsamLog.swift (use FlotsamLog)" "$hits"
# FR-000-10: every interpolation inside a Logger call carries an explicit privacy: qualifier, so the policy is visible
# at the call site. awk tracks the span from a logger call to its closing ")" line; interpolations elsewhere (plain
# string building) are not log messages and are not checked.
hits=$(awk '
  /(logger|Logger\(.*\))[^"]*\.(log|info|notice|error|fault|debug)\(/ { inlog = 1 }
  inlog && /\\\(/ && !/privacy:/ { print FILENAME ":" NR ": " $0 }
  inlog && /^[[:space:]]*\)[[:space:]]*$/ { inlog = 0 }
' "$SRC/FlotsamBase/Logging/FlotsamLog.swift")
[ -n "$hits" ] && fail "Logger interpolation without a privacy: qualifier in FlotsamLog.swift" "$hits"

# Third-party packages: GRDB only (ADR-0010).
hits=$(grep -hE '\.package\(url:' Packages/FlotsamCore/Package.swift | grep -v 'groue/GRDB.swift')
[ -n "$hits" ] && fail "dependency outside the allowlist in Package.swift" "$hits"

# FR-000-15: no crash reporter, analytics or remote-logging SDK (anti-truth A1). The package allowlist above covers
# SwiftPM; this also catches an SDK declared in project.yml (the App target) or imported in source.
SDKS='Sentry|Crashlytics|Firebase|Mixpanel|Amplitude|Bugsnag|PostHog|TelemetryDeck|AppCenter|Datadog|NewRelic|Segment|Rollbar|Instabug|Countly|Flurry|Heap|Smartlook|LogRocket|Embrace|Honeycomb|Raygun|PLCrashReporter|CocoaLumberjack|SwiftyBeaver'
hits=$(grep -rnEi "($SDKS)" Packages/FlotsamCore/Package.swift project.yml 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
[ -n "$hits" ] && fail "crash/analytics/logging SDK referenced in a manifest" "$hits"
hits=$(grep -rnE "^(@testable )?import ($SDKS)" "$SRC" App --include='*.swift' 2>/dev/null)
[ -n "$hits" ] && fail "crash/analytics/logging SDK imported" "$hits"

if [ "$failures" -eq 0 ]; then echo "architecture checks passed"; else echo "$failures violation(s)"; exit 1; fi
