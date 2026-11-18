#!/usr/bin/env bash
# Runs the opt-in S2 perf harnesses (capture latency, 50k search latency) and prints their PERF result lines.
# Per-query detail lines (PERFQ) are left in the swift test log; run the swift test command by hand to see them.
# Measurement only: nothing here is a pass/fail gate. Normal `swift test` skips these (they need FLOTSAM_PERF=1).
# Usage: bin/perf.sh [debug]    (default: release; `debug` falls back to a debug build)
set -uo pipefail
cd "$(dirname "$0")/.."
config=release
[ "${1:-}" = "debug" ] && config=debug
log="$(mktemp -t flotsam-perf)"
trap 'rm -f "$log"' EXIT
# `-enable-testing` keeps @testable imports working in a release build; optimisation stays on.
extra=()
[ "$config" = "release" ] && extra=(-Xswiftc -enable-testing)
FLOTSAM_PERF=1 swift test -c "$config" "${extra[@]}" --package-path Packages/FlotsamCore --filter FlotsamPerfTests >"$log" 2>&1
status=$?
grep -E '^PERF ' "$log"
if [ "$status" -ne 0 ]; then
  echo "perf.sh: swift test exited $status; tail of its output:" >&2
  tail -n 40 "$log" >&2
fi
exit "$status"
