# Screenshot harness

`bin/shots.sh <outdir>` stages eight surfaces, each in light and dark, and writes 16 PNGs named
`NN-<screen>-<light|dark>.png`. It exists so a second machine (Session 2) can produce the same pictures on demand.

## Run

```sh
bin/shots.sh ~/flotsam-shots              # build Debug if needed, 16 passes, prints the folder and file list
bin/shots.sh ~/flotsam-shots --only shelf # one screen (name or stage)
bin/shots.sh --publish 3 [<outdir>]       # commit the PNGs to the orphan branch s2/shots under round-3/ and push
```

Each pass launches its own isolated Debug instance (temporary data folder, temporary defaults suite, fake secure store;
see AGENT-LAUNCH.md), seeds about 40 invented items, stages one surface, captures it and ends only its own process. It
never touches the real data, settings, login items or history. Screenshot watching and typed triggers are off.
The script refuses to run while a Flotsam is already running.

## Host needs

- Screen Recording permission for the terminal (or host) that runs the script.
- An awake, unlocked display. Windows open on the display the pointer is on; the harness moves the pointer to the main
  display first. Do not use the machine while it runs (windows take focus for a second or two per pass).
- Nothing else running as Flotsam.

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
  NOTES.txt in the output folder says so. Window-only has flat materials: dark panels read mid-grey. Region capture
  failed on the build Mac (display not capturable) and is unverified on S2. `SHOTS_CAPTURE=window` forces the fallback.
- The menu-bar menu follows the system menu appearance, not the forced light or dark, so both menu files may look alike.
  If the real menu cannot be captured, a staged copy of its rows in a window is used and NOTES.txt says so.
- The preview's absolute "Copied" time is wall-clock and differs between runs. Relative times ("12m ago") are fixed.
- Onboarding step 2 shows the host's real paste permission state ("Granted" or not).
- Pixel size follows the display scale.
- Staging code is Debug-only (`#if DEBUG`); a Release build contains none of it (checked with `strings` and `nm`).
