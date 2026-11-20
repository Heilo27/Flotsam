# Screenshot harness

`bin/shots.sh <outdir>` stages eight surfaces, each in light and dark, and writes 16 PNGs named
`NN-<screen>-<light|dark>.png`. It exists so a second machine (Session 2) can produce the same pictures on demand.

## Run

```sh
bin/shots.sh ~/flotsam-shots              # build Debug if needed, 16 passes, prints the folder and file list
bin/shots.sh ~/flotsam-shots --only shelf # one screen (name or stage); NOTES.txt keeps the other screens
bin/shots.sh --publish 3 [<outdir>]       # commit the PNGs to the orphan branch s2/shots under round-3/ and push
```

Each pass launches its own isolated Debug instance (temporary data folder, temporary defaults suite, fake secure store;
see AGENT-LAUNCH.md), seeds about 40 invented items, stages one surface, captures it and ends only its own process. It
never touches the real data, settings, login items or history. Screenshot watching and typed triggers are off.
The script refuses to run while a Flotsam is already running.

## Host needs

Set these up before a run; the harness cannot do them for you.

- Screen Recording permission for the terminal (or host) that runs the script. Without it a screen capture leaves out
  every other app's windows.
- An awake, unlocked display. A locked or asleep display captures as bare wallpaper and `screencapture -R` is refused
  ("could not create image from rect"); the staged app detects this and the pass fails with "the main display is asleep
  or the screen is locked". Keep the display awake for the whole run (for example `caffeinate -d` in another tab).
- Do Not Disturb (a Focus) turned on. Otherwise macOS banners (for example "Login Item Added") can land on screen and end
  up in the Shelf shot, which sits at the screen edge where banners appear.
- Windows open on the display the pointer is on; the harness moves the pointer to the main display first. Do not use the
  machine while it runs (windows take focus for a second or two per pass).
- Nothing else running as Flotsam.

## Fixed launch path

The script copies the built app to one fixed place (`~/Library/Caches/flotsam-shots/Flotsam.app`, overridable with
`SHOTS_APP_PATH`) with `rsync --delete` and launches it from there every run, whichever worktree built it. macOS
background-task management re-announces a stale login item ("Login Item Added" banner, even with Focus on) each time
the app shows up at a new bundle path; a worktree path, or a fresh build folder, is a new path. One path means at most
one announcement, on the first ever run.

## Checks before a capture

Each pass checks, from the staged app, that its target window is in the on-screen window list, owned by the staged
process, at the expected level and title, on the main display, and above the backdrop. Otherwise the pass fails with the
reason; no pass reports ok on an empty frame. The backdrop is installed at launch before the onboarding window opens
(onboarding opens during launch; a later backdrop was ordered above it and hid it). The menu is the real NSMenu opened
at a fixed spot near the top right (not under the status item, whose position depends on the host's menu bar) and the
frame is cropped to the menu plus 24 pt of padding, the top stopping below the system menu bar. NOTES.txt records the
capture mode each pass used (region, full-display plus crop, or window-only).

## What sits behind the panels

Every staged launch first opens a full-screen backdrop window on the main display (Debug builds and the shots launch
flag only): a soft gradient drawn in code from fixed colours, one for light and one for dark. It hides everything behind
it (other apps, the terminal, the desktop), so the Library, Shelf and menu glass blur the same pixels on every host, and
the transparent corners of rounded panels show the backdrop, never another app. It sits at the normal window level,
under Flotsam's panels (floating) and the pop-up menu (level 101), and cannot become key or main, so it takes no focus.
The system menu bar and Dock are above it by design. The launched instance also gets a throw-away home
(`CFFIXED_USER_HOME`) so file lookups under the home (Library, Documents, the screenshot folder default) land in a temporary folder.
It does not redirect the preferences daemon, so preferences isolation is still `FLOTSAM_DEFAULTS_SUITE` (a temporary
domain, deleted after each pass); `FLOTSAM_DATA_DIR` is its own temporary absolute path.

## Screens

| File | Stage | Shows |
| --- | --- | --- |
| 01-library-standard | library | Library, standard layout, a result selected, preview open |
| 02-library-compact | library-compact | Library, compact layout |
| 03-library-empty | library-empty | Search with no results |
| 04-shelf | shelf | Shelf open with cards (pinned and recent) |
| 05-menu-bar-menu | menu | The real menu-bar menu, opened and captured |
| 06-settings-general | settings | Settings, General pane |
| 07-onboarding | onboarding | Onboarding step 2 (clipboard access) |
| 08-shortcut-editor | shortcut | Shortcut and Trigger window for the item that has a shortcut |

Fixtures (ShotsFixtures.swift): text, links, code, colours, four generated PNGs, a file, a bundle, two tags (Work, Home),
two pinned items, one note and one item with a shortcut. All invented; nothing real.

## Capture modes and known limits

- Default: region capture (`screencapture -R`) of the staged window over a fixed solid backdrop, so translucent
  materials look the same on every host. If it fails the script falls back to window-only capture (`-l`), and
  NOTES.txt in the output folder says so. If `-R` is refused, the script captures the whole main display and
  crops the same rectangle with `sips`. Window-only has flat materials: dark panels read mid-grey. Region capture failed
  on the build Mac (display locked or asleep) and is unverified on S2. `SHOTS_CAPTURE=window` forces the fallback.
- The menu-bar menu follows the system menu appearance, not the forced light or dark, so both menu files may look alike.
  If the real menu cannot be captured, a staged copy of its rows in a window is used and NOTES.txt says so.
- NOTES.txt: a full run rewrites it. An `--only` run replaces only the lines of the screens it re-captured and keeps
  the rest, so the notes from the full run survive a single-screen retake.
- The preview's absolute "Copied" time is wall-clock and differs between runs. Relative times ("12m ago") are fixed.
- Onboarding step 2 shows the host's real paste permission state ("Granted" or not).
- Pixel size follows the display scale.
- Staging code is Debug-only (`#if DEBUG`); a Release build contains none of it (checked with `strings` and `nm`).
