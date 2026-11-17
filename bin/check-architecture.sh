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

# Crash/analytics/logging SDK names (FR-000-15); used by the source-import rule in the awk pass and the manifest rule below.
SDKS='Sentry|Crashlytics|Firebase|Mixpanel|Amplitude|Bugsnag|PostHog|TelemetryDeck|AppCenter|Datadog|NewRelic|Segment|Rollbar|Instabug|Countly|Flurry|Heap|Smartlook|LogRocket|Embrace|Honeycomb|Raygun|PLCrashReporter|CocoaLumberjack|SwiftyBeaver'
LOG_FILE="$SRC/FlotsamBase/Logging/FlotsamLog.swift"

# Every rule that reads Swift source (as opposed to manifests, the catalogue, or import-graph bookkeeping) runs in ONE awk
# pass (SWIFT_LINT_AWK below). It first strips comments (nested too) and string literals (plain, multi-line, raw;
# interpolations are kept as code), then runs the rules on what is left, so a token inside a comment or a string is never a
# violation. Rules covered: FR-000-02 / FR-000-09 / AC-000-01 (print/NSLog/dump/debugPrint, try!, as!, force-unwrap, thrown
# errors across a module boundary, fatalError, localizedDescription, Logger/os_log/.debug, the log privacy qualifier),
# FR-000-05 (user-facing literals; it needs only the fact that a literal starts there, which the stripper keeps as "0),
# plus the network, UserDefaults, GRDB and SDK-import bans. Hits are "KIND<TAB>file:line:original line".
IFS= read -r -d '' SWIFT_LINT_AWK <<'AWK_EOF'
# Swift source linter (see the rule list above the heredoc). Prints "KIND<TAB>file:line:original line" per violation.
# Pass 1 (san_line) turns each file into code-only text: comments (line, block, nested) become nothing, every string
# literal (plain, multi-line, raw) becomes the two characters "0 (a literal starts here), and only the code inside \( )
# interpolations is kept (re-emitted as \( so the log privacy rule can see them). Comment text is kept apart (lcom) so the
# fatal-ok: annotation, which lives in a comment, can still be read.
# Line numbers are preserved. Pass 2 runs the rules on that text; throws detection (scan_decls) is a small
# declaration scanner so it sees multi-line signatures, default arguments, accessors, and members that inherit
# public from a protocol or extension.
function hashes_follow(s, p, h,   k) {
  for (k = 0; k < h; k++) if (substr(s, p + k, 1) != "#") return 0
  return 1
}
function san_line(s,   n, i, c, two, out, h, j, k, m) {
  out = ""; lcom = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1); m = mk[sp]
    if (m == "B") {
      lcom = lcom c
      two = substr(s, i, 2)
      if (two == "/*") { bc[sp]++; i += 2 }
      else if (two == "*/") { bc[sp]--; i += 2; if (bc[sp] == 0) { sp--; out = out " " } }
      else i++
      continue
    }
    if (m == "S" || m == "M") {
      h = hh[sp]
      if (c == "\\" && hashes_follow(s, i + 1, h)) {
        j = i + 1 + h
        if (substr(s, j, 1) == "(") { sp++; mk[sp] = "C"; ip[sp] = 1; pd[sp] = 0; out = out "\\("; i = j + 1 }
        else i = j + 1
        continue
      }
      if (m == "S" && c == "\"" && hashes_follow(s, i + 1, h)) { sp--; i += 1 + h; continue }
      if (m == "M" && substr(s, i, 3) == "\"\"\"" && hashes_follow(s, i + 3, h)) { sp--; i += 3 + h; continue }
      i++; continue
    }
    two = substr(s, i, 2)
    if (two == "//") { lcom = lcom substr(s, i); break }
    if (two == "/*") { sp++; mk[sp] = "B"; bc[sp] = 1; i += 2; continue }
    if (c == "#" || c == "\"") {
      h = 0; j = i
      while (substr(s, j, 1) == "#") { h++; j++ }
      if (substr(s, j, 1) == "\"") {
        sp++; hh[sp] = h; out = out "\"0"
        if (substr(s, j, 3) == "\"\"\"") { mk[sp] = "M"; i = j + 3 } else { mk[sp] = "S"; i = j + 1 }
        continue
      }
      out = out substr(s, i, h); i += h; continue
    }
    if (c == "(") { if (ip[sp]) pd[sp]++ }
    else if (c == ")" && ip[sp]) {
      if (pd[sp] == 0) { sp--; out = out ")"; i++; continue }
      pd[sp]--
    }
    out = out c; i++
  }
  # A single-line string cannot span lines: drop an unterminated one (and anything inside it) at end of line.
  for (k = 1; k <= sp; k++) if (mk[k] == "S") { sp = k - 1; break }
  gsub(/[\200-\377]/, "A", out)                 # non-ASCII bytes: identifier characters
  gsub(/(private|fileprivate|internal|public|package|open)[ \t]*\([ \t]*set[ \t]*\)/, "", out)   # private(set) is not an access level for the declaration
  return out
}

function resethdr() { hthrow = 0; tline = 0; hfirst = ""; acc = ""; declKw = "" }
function hit(kind, L,   key) {
  key = kind SUBSEP L
  if (key in seen) return
  seen[key] = 1
  printf "%s\t%s:%d:%s\n", kind, fname, L, orig[L]
}
# A header is the text of one declaration up to its { } or ; . Public if it says so, or if it sits directly in a public
# protocol / public extension / accessor block of a public property.
function evaluate(   p) {
  if (!hthrow) return
  if (ck[top] == "A") { if (cm[top] && hfirst ~ /^(get|set|_read|_modify|willSet|didSet)$/) hit("THROWS", tline); return }
  p = (acc in PUB) ? 1 : (acc != "" ? 0 : cm[top])
  if (p) hit("THROWS", tline)
}
function push_ctx(   p) {
  p = (acc in PUB) ? 1 : (acc != "" ? 0 : cm[top])
  top++; ck[top] = "B"; cm[top] = 0
  if (hfirst in DECL) {
    if (declKw == "var" || declKw == "let" || declKw == "subscript") { ck[top] = "A"; cm[top] = p }
    else if (declKw == "protocol" || declKw == "extension") cm[top] = (acc in PUB) ? 1 : 0
  }
}
function word(w, L, first) {
  if (first && pdepth == 0 && declKw != "" && ((w in START) || substr(w, 1, 1) == "@")) { evaluate(); resethdr() }
  if (hfirst == "" && substr(w, 1, 1) != "@" && !(w in MODS)) hfirst = w
  if ((w == "throws" || w == "rethrows") && !hthrow) { hthrow = 1; tline = L }
  if (pdepth == 0) {
    if (w in ACC) { if (acc == "" && declKw == "") acc = w }
    else if (w in DECL) { if (declKw == "" || (declKw == "class" && (w in MEMBER))) declKw = w }
  }
}
function scan_decls(nl,   L, s, n, i, j, c, w, first) {
  top = 0; cm[0] = 0; ck[0] = "B"; pdepth = 0; resethdr()
  for (L = 1; L <= nl; L++) {
    s = san[L]; n = length(s); first = 1; i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == " " || c == "\t") { i++; continue }
      if (c ~ /[A-Za-z0-9_$@#]/) {
        j = i
        while (j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_$@#]/) j++
        w = substr(s, i, j - i); i = j
        if (first && pdepth == 0 && w ~ /^#(if|else|elseif|endif)$/) { evaluate(); resethdr(); break }
        word(w, L, first); first = 0
        continue
      }
      first = 0
      if (c == "(" || c == "[") pdepth++
      else if (c == ")" || c == "]") { if (pdepth > 0) pdepth-- }
      else if (pdepth == 0) {
        if (c == "{") { evaluate(); push_ctx(); resethdr() }
        else if (c == "}") { evaluate(); if (top > 0) top--; resethdr() }
        else if (c == ";") { evaluate(); resethdr() }
      }
      i++
    }
  }
  evaluate()
}
function finish(   L, t) {
  for (L = 1; L <= nl; L++) {
    t = san[L]
    if (t ~ /(^|[^A-Za-z0-9_$.])(print|NSLog|dump|debugPrint)[ \t]*\(/ || \
        t ~ /(^|[^A-Za-z0-9_$.])(Swift|Foundation)[ \t]*\.[ \t]*(print|NSLog|dump|debugPrint)[ \t]*\(/ || \
        t ~ /(^|[^A-Za-z0-9_$])try!/) hit("BANNED", L)
    if (t ~ /(^|[^A-Za-z0-9_$])as!/) hit("FORCECAST", L)
    # Only the two Fatal codes (FR-000-04) and unreachable programmer-error invariants may stop the process; the latter
    # must say why in a comment on the same line with 'fatal-ok:'.
    if (t ~ /(fatalError|preconditionFailure|precondition)\(/ && lcm[L] !~ /fatal-ok:/) hit("FATAL", L)
    # localizedDescription can embed file paths (FR-000-01, FR-000-10); UnderlyingErrorInfo is the only way to carry a cause.
    if (t ~ /localizedDescription/) hit("LOCDESC", L)
    # FR-000-09: one logging entry point (Logging/FlotsamLog.swift, filtered by the shell).
    if (t ~ /(^|[^A-Za-z0-9_])Logger\(|os_log\(|\.debug\(/) hit("LOGGER", L)
    # FR-000-05: a literal handed to a view or an AppKit text property bypasses the String Catalog. Heuristic by design:
    # it catches the common SwiftUI and AppKit entry points; code review and the catalogue test cover the rest.
    if (t ~ /(Text|Button|Label|Toggle|Picker|Section|TextField|SecureField|Menu|Link|MenuBarExtra|Stepper|GroupBox|DisclosureGroup)\("|\.(help|navigationTitle|accessibilityLabel|accessibilityHint|badge|confirmationDialog|alert)\("|\.(messageText|informativeText|title|stringValue|toolTip|placeholderString|label) = "|withTitle: "/) hit("USTRING", L)
    # Zero network in v1.0; UserDefaults only behind the SettingsStore adapter (ADR-0009); GRDB/SQLite only in Storage.
    if (t ~ /URLSession|NWConnection|NWPathMonitor|WKWebView|CFNetwork|Sparkle/) hit("NETWORK", L)
    if (t ~ /UserDefaults/) hit("USERDEFAULTS", L)
    if (t ~ /^(@testable )?import [A-Za-z0-9_]+/) hit("IMPORT", L)
    if (t ~ /import[ \t]+(GRDB|SQLite3)/) hit("GRDBIMPORT", L)
    if (t ~ ("^[ \t]*(@testable[ \t]+)?import[ \t]+(" sdks ")")) hit("SDKIMPORT", L)
    # Drop the try! / as! tokens (their own rules report them), then flag a ! that follows an identifier char, ) or ]
    # and is not the start of !=.
    gsub(/(^|[^A-Za-z0-9_$])try!/, " try ", t); gsub(/(^|[^A-Za-z0-9_$])as!/, " as ", t)
    if (t ~ /[]A-Za-z0-9_)]!([^=]|$)/) hit("UNWRAP", L)
  }
  scan_decls(nl)
  # FR-000-10: every interpolation inside a Logger call carries an explicit privacy: qualifier, so the policy is visible
  # at the call site. Tracks the span from a logger call to its closing ")" line; interpolations elsewhere (plain string
  # building) are not log messages and are not checked.
  if (fname == privfile) {
    inlog = 0
    for (L = 1; L <= nl; L++) {
      t = san[L]
      if (t ~ /(logger|Logger\(.*\))[^"]*\.(log|info|notice|error|fault|debug)\(/) inlog = 1
      if (inlog && t ~ /\\\(/ && t !~ /privacy:/) hit("LOGPRIVACY", L)
      if (inlog && t ~ /^[ \t]*\)[ \t]*$/) inlog = 0
    }
  }
}
BEGIN {
  split("public package open", a, " "); for (k in a) PUB[a[k]] = 1
  for (k in PUB) ACC[k] = 1
  split("private fileprivate internal", a, " "); for (k in a) ACC[a[k]] = 1
  split("func var let init deinit subscript typealias associatedtype case struct class enum actor protocol extension", a, " "); for (k in a) DECL[a[k]] = 1
  split("func var let init subscript", a, " "); for (k in a) MEMBER[a[k]] = 1
  split("static final override mutating nonmutating lazy weak unowned dynamic required convenience indirect nonisolated isolated optional prefix postfix infix distributed borrowing consuming", a, " "); for (k in a) MODS[a[k]] = 1
  for (k in ACC) MODS[k] = 1
  for (k in DECL) START[k] = 1
  for (k in MODS) START[k] = 1
  split("if guard for while switch return throw defer do try", a, " "); for (k in a) START[a[k]] = 1
}
FNR == 1 { if (fname != "") finish(); fname = FILENAME; sp = 0; mk[0] = "C"; ip[0] = 0; split("", seen); split("", san); split("", orig); split("", lcm) }
{ nl = FNR; orig[FNR] = $0; san[FNR] = san_line($0); lcm[FNR] = lcom }
END { if (fname != "") finish() }
AWK_EOF
swift_lint=$(find "$SRC" App -name '*.swift' -print0 2>/dev/null | sort -z | LC_ALL=C xargs -0 awk -v sdks="$SDKS" -v privfile="$LOG_FILE" "$SWIFT_LINT_AWK")
lint_hits() { printf '%s\n' "$swift_lint" | awk -v kinds="$1" 'BEGIN { n = split(kinds, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 } { t = index($0, "\t"); if (t > 0 && (substr($0, 1, t - 1) in want)) print substr($0, t + 1) }'; }

# Return the modules one target imports (import lines at column 0, as read by the awk pass, so commented-out and quoted
# imports do not count).
imports_of() { lint_hits IMPORT | grep "^$SRC/$1/" | sed -E 's/^[^:]*:[0-9]+:(@testable )?import ([A-Za-z0-9_]+).*/\2/' | sort -u; }

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

hits=$(lint_hits BANNED)
[ -n "$hits" ] && fail "print/NSLog/dump/try! used" "$hits"
hits=$(lint_hits THROWS)
[ -n "$hits" ] && fail "public/package API declared 'throws' (return FlotsamResult; nothing in the package throws, WallClock.sleep returns early on cancellation)" "$hits"
hits=$(lint_hits FORCECAST)
[ -n "$hits" ] && fail "force cast (as!) used" "$hits"
hits=$(lint_hits UNWRAP)
[ -n "$hits" ] && fail "force unwrap (!) used" "$hits"
hits=$(lint_hits FATAL)
[ -n "$hits" ] && fail "fatalError/precondition without a 'fatal-ok: <reason>' annotation" "$hits"
hits=$(lint_hits LOCDESC)
[ -n "$hits" ] && fail "localizedDescription used (use UnderlyingErrorInfo)" "$hits"
hits=$(lint_hits NETWORK)
[ -n "$hits" ] && fail "network API referenced" "$hits"
hits=$(lint_hits GRDBIMPORT | grep "^$SRC/" | grep -v "^$SRC/FlotsamStorage/")
[ -n "$hits" ] && fail "GRDB/SQLite3 imported outside Storage" "$hits"

# FR-000-05: the String Catalog is the only home for user-facing text (the USTRING rule in the awk pass); the keys in it
# must follow the naming scheme.
hits=$(lint_hits USTRING)
[ -n "$hits" ] && fail "user-facing string literal outside the catalogue (use FlotsamStrings.text(forKey:))" "$hits"
# Catalogue keys are 'error.<code>' or 'ui.<screen>.<name>' (FR-000-05).
CATALOGUE="$SRC/FlotsamBase/Resources/Localizable.xcstrings"
hits=$(grep -E '^    "[^"]+" : \{' "$CATALOGUE" | sed -E 's/^    "([^"]+)".*/\1/' | grep -vE '^(error\.[A-Z]{3}-[A-Z]{2,3}-[0-9]{3}|ui\.[a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*)$')
[ -n "$hits" ] && fail "catalogue key does not match error.<code> or ui.<screen>.<name>" "$hits"

# UserDefaults only behind SettingsStore adapters (ADR-0009): Base/Ports/Adapters.swift is the single adapter.
hits=$(lint_hits USERDEFAULTS | grep -v '^[^:]*Ports/Adapters\.swift:')
[ -n "$hits" ] && fail "UserDefaults used outside Ports/Adapters.swift" "$hits"

# FR-000-09: one logging entry point. Logger, os_log and .debug( live only in Logging/FlotsamLog.swift, so categories,
# levels and the privacy policy (FR-000-10) cannot be bypassed by a call site that builds its own Logger.
hits=$(lint_hits LOGGER | grep -v "^$LOG_FILE:")
[ -n "$hits" ] && fail "Logger/os_log/.debug used outside Logging/FlotsamLog.swift (use FlotsamLog)" "$hits"
hits=$(lint_hits LOGPRIVACY)
[ -n "$hits" ] && fail "Logger interpolation without a privacy: qualifier in FlotsamLog.swift" "$hits"

# Third-party packages: GRDB only (ADR-0010).
hits=$(grep -hE '\.package\(url:' Packages/FlotsamCore/Package.swift | grep -v 'groue/GRDB.swift')
[ -n "$hits" ] && fail "dependency outside the allowlist in Package.swift" "$hits"

# FR-000-15: no crash reporter, analytics or remote-logging SDK (anti-truth A1). The package allowlist above covers
# SwiftPM; this also catches an SDK declared in project.yml (the App target) or imported in source.
hits=$(grep -rnEi "($SDKS)" Packages/FlotsamCore/Package.swift project.yml 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
[ -n "$hits" ] && fail "crash/analytics/logging SDK referenced in a manifest" "$hits"
hits=$(lint_hits SDKIMPORT)
[ -n "$hits" ] && fail "crash/analytics/logging SDK imported" "$hits"

if [ "$failures" -eq 0 ]; then echo "architecture checks passed"; else echo "$failures violation(s)"; exit 1; fi
