#!/usr/bin/env bash
# Deterministic screenshot harness (docs/SCREENSHOTS.md).
#
#   bin/shots.sh <outdir> [--only <screen>]    build if needed, stage 8 screens x light/dark, write NN-<screen>-<light|dark>.png
#   bin/shots.sh --publish <round> [<outdir>]  commit those PNGs to the orphan branch s2/shots under round-<N>/ and push
#
# Every pass launches its own ISOLATED Debug instance: a temporary data folder, a temporary defaults suite and the fake
# secure store (docs/AGENT-LAUNCH.md). It never touches the real data, settings, login items or history. The launch is
# the binary itself, never `open`. Needs Screen Recording permission for the terminal or host running it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILT_APP="$ROOT/build/Build/Products/Debug/Flotsam.app"
# The instance is always launched from ONE fixed path, whichever worktree built it (docs/SCREENSHOTS.md, "Fixed launch
# path"): macOS announces a "Login Item Added" banner for a stale login item each time the app shows up at a new bundle path.
STABLE_APP="${SHOTS_APP_PATH:-$HOME/Library/Caches/flotsam-shots/Flotsam.app}"
APP="$STABLE_APP/Contents/MacOS/Flotsam"

# number-name:stage (the stage is the FLOTSAM_SHOTS_STAGE value)
SCREENS=(
  "01-library-standard:library"
  "02-library-compact:library-compact"
  "03-library-empty:library-empty"
  "04-shelf:shelf"
  "05-menu-bar-menu:menu"
  "06-settings-general:settings"
  "06b-settings-library:settings-library"
  "07-onboarding:onboarding"
  "08-shortcut-editor:shortcut"
)
APPEARANCES=(light dark)

die() { echo "shots: $*" >&2; exit 1; }

# Publish scratch worktree. Script-global on purpose: the EXIT trap runs after publish() has returned (or from die's
# exit inside it), when a `local` is already gone and `set -u` would abort the cleanup with "unbound variable".
PUBLISH_WORK=""
cleanup_publish() {
  [[ -n "$PUBLISH_WORK" ]] || return 0
  git -C "$ROOT" worktree remove --force "$PUBLISH_WORK" >/dev/null 2>&1 || true
  git -C "$ROOT" branch -D s2/shots-new >/dev/null 2>&1 || true
}

publish() {
  local round="${1:-}" outdir="${2:-}"
  [[ "$round" =~ ^[0-9]+$ ]] || die "--publish needs a round number"
  if [[ -z "$outdir" ]]; then
    [[ -f build/.shots-last ]] || die "no outdir given and no previous run recorded"
    outdir="$(cat build/.shots-last)"
  fi
  [[ -d "$outdir" ]] || die "no such folder: $outdir"
  shopt -s nullglob
  local pngs=("$outdir"/[0-9][0-9]*-*-light.png "$outdir"/[0-9][0-9]*-*-dark.png)
  ((${#pngs[@]} > 0)) || die "no screenshots in $outdir"
  local expected=$((${#SCREENS[@]} * ${#APPEARANCES[@]}))
  ((${#pngs[@]} == expected)) || echo "shots: warning: ${#pngs[@]} of $expected files in $outdir" >&2

  local work="$ROOT/.claude/worktrees/shots-publish-$$"
  PUBLISH_WORK="$work"
  trap cleanup_publish EXIT
  if git ls-remote --exit-code --heads origin s2/shots >/dev/null 2>&1; then
    git fetch --quiet origin s2/shots
    git worktree add --quiet --detach "$work" origin/s2/shots
  else
    git worktree add --quiet --detach "$work" HEAD
    git -C "$work" checkout --quiet --orphan s2/shots-new
    git -C "$work" rm -rf --quiet . >/dev/null 2>&1 || true
    git -C "$work" clean -fdxq
  fi
  rm -rf "$work/round-$round"
  mkdir -p "$work/round-$round"
  cp "${pngs[@]}" "$work/round-$round/"
  [[ -f "$outdir/NOTES.txt" ]] && cp "$outdir/NOTES.txt" "$work/round-$round/"
  git -C "$work" add "round-$round"
  git -C "$work" commit --quiet -m "shots: round $round (fixture data only)" || die "nothing to commit for round $round"
  git -C "$work" push --quiet origin HEAD:refs/heads/s2/shots
  echo "published round-$round to origin/s2/shots: $(git -C "$work" rev-parse --short HEAD)"
}

if [[ "${1:-}" == "--publish" ]]; then
  publish "${2:-}" "${3:-}"
  exit 0
fi

OUT="${1:-}"
[[ -n "$OUT" && "$OUT" != -* ]] || die "usage: bin/shots.sh <outdir> [--only <screen>] | --publish <round> [<outdir>]"
shift
ONLY=""
if [[ "${1:-}" == "--only" ]]; then ONLY="${2:-}"; [[ -n "$ONLY" ]] || die "--only needs a screen"; fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
# This run's notes go to a scratch file and are merged into NOTES.txt at the end: a full run replaces NOTES.txt, an
# --only run replaces just its own screens' lines and keeps the rest (docs/SCREENSHOTS.md).
NEW_NOTES="$OUT/.notes.new"
: > "$NEW_NOTES"
SELECTED=()

# A real Flotsam shares the Carbon hotkeys and the pasteboard; do not run next to one.
if pgrep -x Flotsam >/dev/null 2>&1; then die "a Flotsam is already running; quit it first (the harness never kills a process it did not start)"; fi

if [[ ! -x "$BUILT_APP/Contents/MacOS/Flotsam" ]] || [[ -n "$(find App Packages project.yml -newer "$BUILT_APP/Contents/MacOS/Flotsam" \( -name '*.swift' -o -name project.yml \) 2>/dev/null | head -1)" ]]; then
  echo "shots: building Debug app"
  bin/build.sh >/dev/null
fi
[[ -x "$BUILT_APP/Contents/MacOS/Flotsam" ]] || die "build did not produce $BUILT_APP"
mkdir -p "$STABLE_APP"
rsync -a --delete "$BUILT_APP/" "$STABLE_APP/"   # overwrite in place: same path every run
[[ -x "$APP" ]] || die "could not install the app at $STABLE_APP"

# crop_display <ctl> <png> <x> <y> <w> <h> <display width in points>: capture the main display and crop the point
# rectangle out of it (pixel scale = capture pixels / display points). Returns non-zero on any failure.
crop_display() {
  local ctl="$1" png="$2" x="$3" y="$4" w="$5" h="$6" dw="$7"
  local full="$ctl/display.png" pxw scale
  ((dw > 0)) || return 1
  screencapture -x -m "$full" 2>>"$ctl/capture.log" && [[ -s "$full" ]] || return 1
  pxw="$(sips -g pixelWidth "$full" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
  [[ "$pxw" =~ ^[0-9]+$ ]] || return 1
  scale="$(awk -v p="$pxw" -v d="$dw" 'BEGIN { printf "%.4f", p / d }')"
  local cx cy cw ch
  read -r cx cy cw ch < <(awk -v s="$scale" -v x="$x" -v y="$y" -v w="$w" -v h="$h" \
    'BEGIN { printf "%d %d %d %d\n", x * s + 0.5, y * s + 0.5, w * s + 0.5, h * s + 0.5 }')
  sips -c "$ch" "$cw" --cropOffset "$cy" "$cx" "$full" --out "$png" >/dev/null 2>>"$ctl/capture.log" && [[ -s "$png" ]]
}

# One pass: launch, wait for ready or failed, capture the window, end our own process.
# Prints "ok" or the failure reason on the last line of stdout.
pass() {
  local stage="$1" appearance="$2" png="$3"
  local ctl; ctl="$(mktemp -d "${TMPDIR:-/tmp}/flotsam-shots.XXXXXX")"
  local suite="flotsam-shots-$$-$RANDOM"
  defaults write "$suite" screenshots.enabled -string false
  defaults write "$suite" triggers.enabled -string false
  # A throw-away home for the launched instance (CFFIXED_USER_HOME): file-based lookups (NSHomeDirectory, ~/Library,
  # ~/Documents, the screenshot folder default) resolve inside $ctl, not the real home. It does NOT redirect cfprefsd:
  # defaults domains still live in the real ~/Library/Preferences, so the suite stays the preferences isolation (and is
  # deleted below). FLOTSAM_DATA_DIR stays an absolute path of its own.
  local fakehome="$ctl/home"
  mkdir -p "$fakehome/Library/Preferences"
  CFFIXED_USER_HOME="$fakehome" FLOTSAM_DATA_DIR="$ctl/data" FLOTSAM_DEFAULTS_SUITE="$suite" FLOTSAM_FAKE_SECURE=1 \
    FLOTSAM_SHOTS_STAGE="$stage" FLOTSAM_SHOTS_APPEARANCE="$appearance" FLOTSAM_SHOTS_CTL="$ctl" \
    "$APP" >"$ctl/stdout.log" 2>"$ctl/stderr.log" &
  local pid=$! result="timeout"
  for _ in $(seq 1 300); do
    if [[ -f "$ctl/ready" ]]; then result="ready"; break; fi
    if [[ -f "$ctl/failed" ]]; then result="$(head -1 "$ctl/failed")"; break; fi
    kill -0 "$pid" 2>/dev/null || { result="the app exited: $(head -1 "$ctl/stderr.log" 2>/dev/null)"; break; }
    sleep 0.2
  done
  if [[ "$result" == "ready" ]]; then
    local wid x y w h; read -r wid x y w h dw sr < "$ctl/ready"
    # Default: the region of the screen the staged window occupies. The window sits on a fixed-colour backdrop, so its
    # materials blur the same thing on every host. SHOTS_CAPTURE=window captures the window alone instead (-l): blur
    # then has nothing behind it and looks flat.
    local mode="${SHOTS_CAPTURE:-region}" captured=0 used="none"
    # Without Screen Recording a screen capture silently leaves out every other app's windows (it returns the bare
    # wallpaper, with no Flotsam in it) and -R is refused. Never produce those: fall back to the window-only capture.
    if [[ "${sr:-1}" == "0" && "$mode" != "window" ]]; then
      echo "shots: Screen Recording is not granted to this host; region capture would be wallpaper only" >&2
      mode="window"
    fi
    if [[ "$mode" == "region" ]] && screencapture -x -R "$x,$y,$w,$h" "$png" 2>"$ctl/capture.log" && [[ -s "$png" ]]; then
      captured=1; result="ok"; used="region capture (screencapture -R)"
    elif [[ "$mode" != "window" ]] && crop_display "$ctl" "$png" "$x" "$y" "$w" "$h" "${dw:-0}"; then
      # -R is refused on some hosts ("could not create image from rect") while a whole-display capture works: take the
      # main display and cut the same rectangle out of it. Same pixels, same backdrop.
      captured=1; result="ok"; used="full-display capture + sips crop"
    elif screencapture -x -o -l "$wid" "$png" 2>>"$ctl/capture.log" && [[ -s "$png" ]]; then
      # A window capture the caller asked for (SHOTS_CAPTURE=window) is its own result: it is not a fallback, so it must
      # never be reported as "region capture failed".
      captured=1; used="window-only capture (screencapture -l)"
      if [[ "${SHOTS_CAPTURE:-region}" == "window" ]]; then result="ok-window-requested"; else result="ok-window"; fi
    fi
    echo "$used" > "$OUT/.mode"
    if ((captured == 0)); then
      result="screencapture failed (is Screen Recording allowed for this terminal, and is the display awake?): $(head -1 "$ctl/capture.log")"
    fi
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  defaults delete "$suite" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$suite.plist"
  rm -rf "$ctl"
  echo "$result"
}

failures=0
for entry in "${SCREENS[@]}"; do
  name="${entry%%:*}"; stage="${entry##*:}"
  [[ -z "$ONLY" || "$ONLY" == "$name" || "$ONLY" == "$stage" ]] || continue
  SELECTED+=("$name")
  for appearance in "${APPEARANCES[@]}"; do
    png="$OUT/$name-$appearance.png"
    rm -f "$OUT/.mode"
    result="$(pass "$stage" "$appearance" "$png")"
    if [[ "$result" != ok* && "$stage" == "menu" ]]; then
      echo "shots: $name-$appearance: real menu not captured ($result); using the staged copy"
      echo "$name-$appearance: staged copy of the menu rows in a window, not the real NSMenu ($result)" >> "$NEW_NOTES"
      result="$(pass menu-staged "$appearance" "$png")"
    fi
    [[ "$result" == ok* && -f "$OUT/.mode" ]] && echo "$name-$appearance: capture mode: $(cat "$OUT/.mode")" >> "$NEW_NOTES"
    if [[ "$result" == "ok-window" ]]; then
      echo "shots: $name-$appearance ok (region capture failed; window-only capture, blur is flat)"
      echo "$name-$appearance: window-only capture (-l); region capture was not available, so materials are not blurred over the backdrop" >> "$NEW_NOTES"
    elif [[ "$result" == "ok-window-requested" ]]; then
      echo "shots: $name-$appearance ok (window-only capture, as requested by SHOTS_CAPTURE=window; blur is flat)"
      echo "$name-$appearance: window-only capture (-l), requested with SHOTS_CAPTURE=window; materials are not blurred over the backdrop" >> "$NEW_NOTES"
    elif [[ "$result" == "ok" ]]; then echo "shots: $name-$appearance ok"
    else echo "shots: $name-$appearance FAILED: $result" >&2; echo "$name-$appearance: FAILED $result" >> "$NEW_NOTES"; failures=$((failures + 1)); fi
  done
done

if [[ -n "$ONLY" && -f "$OUT/NOTES.txt" ]]; then
  # Keep every line that does not belong to a screen this run re-captured, then add the fresh lines; stable sort by
  # screen number keeps the file in screen order.
  kept="$OUT/.notes.kept"; : > "$kept"
  while IFS= read -r line || [[ -n "$line" ]]; do
    drop=0
    for n in ${SELECTED[@]+"${SELECTED[@]}"}; do [[ "$line" == "$n-"* ]] && drop=1; done
    ((drop)) || printf '%s\n' "$line" >> "$kept"
  done < "$OUT/NOTES.txt"
  cat "$kept" "$NEW_NOTES" | sort -s -t- -k1,1n > "$OUT/NOTES.txt"
  rm -f "$kept"
else
  cp "$NEW_NOTES" "$OUT/NOTES.txt"
fi
rm -f "$NEW_NOTES"

echo "$OUT" > build/.shots-last
echo
echo "output: $OUT"
ls -1 "$OUT"
((failures == 0)) || { echo "shots: $failures pass(es) failed" >&2; exit 1; }
