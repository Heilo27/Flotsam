#!/usr/bin/env bash
# Enforces ADR-0001 / ADR-0009 / ADR-0010 rules that a compiler cannot. Exit 1 on any violation.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=Packages/FlotsamCore/Sources
failures=0
fail() { echo "ARCH VIOLATION: $1"; failures=$((failures + 1)); }

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
[ -n "$hits" ] && fail "GRDB/SQLite3 imported outside Storage: $hits"

# Zero network in v1.0.
hits=$(grep -rnE 'URLSession|NWConnection|NWPathMonitor|WKWebView|CFNetwork|Sparkle' "$SRC" App 2>/dev/null)
[ -n "$hits" ] && fail "network API referenced: $hits"

# No print/NSLog/dump; no try! (FR-000-02).
hits=$(grep -rnE '(^|[^A-Za-z_.])(print|NSLog|dump)\(|try!' "$SRC" App 2>/dev/null)
[ -n "$hits" ] && fail "print/NSLog/dump/try! used: $hits"

# UserDefaults only behind SettingsStore adapters (ADR-0009): Base/Ports/Adapters.swift is the single adapter.
hits=$(grep -rn 'UserDefaults' "$SRC" App 2>/dev/null | grep -v 'Ports/Adapters.swift')
[ -n "$hits" ] && fail "UserDefaults used outside Ports/Adapters.swift: $hits"

# Third-party packages: GRDB only (ADR-0010).
hits=$(grep -hE '\.package\(url:' Packages/FlotsamCore/Package.swift | grep -v 'groue/GRDB.swift')
[ -n "$hits" ] && fail "dependency outside the allowlist in Package.swift: $hits"

if [ "$failures" -eq 0 ]; then echo "architecture checks passed"; else echo "$failures violation(s)"; exit 1; fi
