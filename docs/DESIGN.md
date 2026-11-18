# Flotsam Design Specification

Status: Phase 6 (TASK-002). Original design; no third-party visual or copy reference.
Sources: `docs/TRUTHS.md`, `docs/PRD.md`, `docs/frd/FRD-000` to `FRD-008`.
Images: `docs/design/NN-name-{light,dark}.png` (2x). Source: `docs/design/src/`.

> Tooling note. The Pencil MCP was not connected, so mockups are HTML/CSS sheets rendered by headless Chrome at 2x. SF Symbols appear as SVG stand-ins; the real symbol names are in §9. Regenerate: `python3 docs/design/src/build.py && zsh docs/design/src/render.sh`. Tokens live in `docs/design/src/tokens.css` and mirror §2.

## 1. Principles and information architecture

1. Native first. System materials, SF Pro, SF Symbols, system controls. The accent is the only brand colour (HIG: Color).
2. Keyboard first. Every Library action has a key (§6). Mouse is optional, never required (WCAG 2.1.1).
3. Quiet. No Dock icon, no badges, no streaks, no nags (SDT: autonomy). Onboarding steps skip; Settings never nags.
4. Light and dark are equal. Both designed and contrast-checked together.
5. Colour never carries meaning alone (WCAG 1.4.1). Tags show a name, statuses show an icon and text.

Surfaces:

| Surface | Type | Image |
|---|---|---|
| Menu-bar item and menu | NSStatusItem + NSMenu | 08 |
| Library | floating NSPanel, 760x480 (min 560x360) | 01, 02, 03, 04 |
| Shelf | edge NSPanel (left, right, bottom, menu bar) | 05 |
| Settings | toolbar window, 6 panes | 06 |
| Onboarding | window, 8 steps | 07 |
| HUD, Notices, alerts | non-activating HUD, submenu, sheets | 08, 04, 06 |

## 2. Tokens

All colour in OKLCH (L C H). CSS custom properties in `tokens.css`; Swift mirrors them as an asset-catalogue `Color` set named `Flotsam/<token>` with Any and Dark appearances.

### 2.1 Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg` | 0.975 0.004 95 | 0.235 0.008 240 | panel body |
| `bg-side` | 0.95 0.006 95 | 0.205 0.008 240 | sidebar |
| `bg-raised` | 1 0 0 | 0.28 0.008 240 | cards, popovers |
| `bg-field` | 1 0 0 | 0.19 0.008 240 | text fields |
| `sep` | 0.88 0.005 95 | 0.34 0.008 240 | hairlines |
| `sep-strong` | 0.80 0.006 95 | 0.42 0.008 240 | decorative dividers only |
| `edge` | 0.64 0.006 95 | 0.58 0.008 240 | control borders (3:1) |
| `t1` | 0.22 0.01 250 | 0.96 0.004 250 | primary text |
| `t2` | 0.46 0.01 250 | 0.78 0.008 250 | secondary text |
| `t3` | 0.53 0.01 250 | 0.69 0.008 250 | tertiary text, hints |
| `accent` | 0.52 0.11 195 | 0.76 0.11 195 | controls, icons |
| `accent-text` | 0.50 0.11 195 | 0.76 0.11 195 | accent text on sidebar |
| `sel` | 0.52 0.11 195 | 0.46 0.09 195 | selected row fill |
| `on-sel` / `on-sel-2` | 1 0 0 / 0.96 0.02 195 | 1 0 0 / 0.93 0.02 195 | text on `sel` |
| `focus` | 0.62 0.13 215 | 0.78 0.12 215 | focus ring, 2 pt |
| `warn` | 0.50 0.12 65 | 0.80 0.13 80 | warnings |
| `err` | 0.50 0.19 25 | 0.76 0.15 25 | errors |
| `ok` | 0.48 0.12 150 | 0.78 0.13 150 | success |

Tint tokens (`accent-tint`, `warn-tint`, `err-tint`) are the base colour at 10 to 16% alpha. `scrim`: 0.2 0.01 250 / 0.28 light, 0.05 0.01 250 / 0.5 dark. HUD: `hud-bg` 0.24 0.01 250 / 0.92 (dark 0.34), `hud-fg` 0.97 0.004 250.

Tag colours (closed set of 8; FRD-004):

| Tag | Light | Dark |
|---|---|---|
| red | 0.58 0.19 25 | 0.72 0.16 25 |
| orange | 0.62 0.16 55 | 0.78 0.15 60 |
| yellow | 0.65 0.13 90 | 0.86 0.15 95 |
| green | 0.58 0.14 150 | 0.78 0.15 150 |
| blue | 0.55 0.17 255 | 0.74 0.13 255 |
| purple | 0.55 0.18 305 | 0.74 0.14 305 |
| pink | 0.60 0.19 355 | 0.77 0.13 355 |
| gray | 0.58 0.01 250 | 0.72 0.01 250 |

Tag colours are decoration. The chip always shows the tag name in `t1`/`t2`, so no contrast is asked of the dot (WCAG 1.4.1).

### 2.2 Contrast (computed, OKLCH to sRGB, WCAG 2.x)

| Pair | Light | Dark | Need |
|---|---|---|---|
| t1 on bg | 16.10 | 14.83 | 4.5 (1.4.3) |
| t2 on bg | 6.62 | 8.33 | 4.5 |
| t3 on bg | 4.91 | 6.01 | 4.5 |
| t3 on bg-side | 4.56 | 6.46 | 4.5 |
| accent-text on bg-side | 4.73 | 8.72 | 4.5 |
| on-sel on sel | 5.05 | 6.69 | 4.5 |
| edge on bg | 3.13 | 3.89 | 3 (1.4.11) |
| edge on bg-field | 3.36 | 4.31 | 3 |
| focus on bg | 3.15 | 8.64 | 3 (1.4.11, 2.4.7) |

`sep-strong` measured 1.74 (light) and 2.18 (dark) against bg, so it never draws a control edge; `edge` does. Known caveat: the switch off-track is low contrast and relies on the knob position and the row label (both visible); VoiceOver reports the value.

### 2.3 Type (SF Pro; HIG: Typography; Dynamic Type n/a on macOS, sizes follow system text styles)

| Role | Size / weight | Use |
|---|---|---|
| Title | 20 / semibold | onboarding title, empty state |
| Headline | 13 / semibold | alert title, section heads |
| Body | 13 / regular | rows, fields, buttons |
| Secondary | 12 / regular | metadata, hints |
| Caption | 11 / regular | badges, footer hints |
| Mono | SF Mono 12 | triggers, shortcuts, text preview |

### 2.4 Geometry

Spacing: 2, 4, 8, 12, 16, 20, 24 pt. Radii: panel 16, popover 12, card 10, row 8, control 6, chip 6. Shadows: `shadow-panel`, `shadow-pop` (dark adds a 0.5 pt light edge so panels separate on dark desktops). Materials: Library and Shelf use `.hudWindow`/`.popover` NSVisualEffectView behind `bg` at 0.82 alpha; Settings and alerts use opaque `bg`.

### 2.5 Motion

Library appears in 120 ms ease-out (scale 0.98 to 1, fade). Shelf slides 150 ms in, 120 ms out. HUD fades 120 ms. Reduce Motion on: every transition becomes a 100 ms cross-fade, no scale, no slide (HIG: Motion; WCAG 2.3.3). No looping or decorative animation anywhere.

### 2.6 Accessibility fallbacks

- Reduce Transparency: material becomes opaque `bg` / `bg-side`.
- Increase Contrast: `sep` becomes `edge`; `t3` becomes `t2`; selection adds a 2 pt `focus` inner ring.
- Hit targets: pointer controls are at least 24x24 pt with 44 pt row height in lists (macOS pointer; WCAG 2.5.8; the 44 pt target applies to Shelf cards and onboarding buttons).
- Focus is always visible: 2 pt `focus` ring, 2 pt offset (WCAG 2.4.7, 2.4.11).

## 3. Layouts

### 3.1 Library (images 01 to 04)

760x480, centred on the pointer's screen, resizable to 560x360 minimum. Three columns: sidebar 168, results 312, preview 280 (preview collapses first below 700 wide, then sidebar below 620). Search field 36 pt at top. Footer hint bar 30 pt.

- Sidebar sections: Library (All, Pinned), Types (Text, Images, Files, Links, Screenshots, Colours), Tags, Apps. Rows 28 pt, count right-aligned, `accent-text` on selected row.
- List rows: 44 pt, 32 pt lead icon or thumbnail, first line `t1` single line, second line `t2` (source app, age). Badges: pin, trigger, Missing (warn). Up to 3 tag chips then "+n". Quick-paste badge ⌘1 to ⌘9 on the first nine rows.
- Grid cells: 120 pt square, thumbnail, name caption, same badges.
- Preview: content, metadata list, tags, note, "Show more" past 12 lines (text) or fit for images.
- Footer: key hints (Paste, Plain text, Copy, Preview, Close); the active sort name (Recent, Oldest, Most Used, A to Z) beside the item count at the right; copy-only mode shows "Press ⌘V to paste" and an "Enable pasting" link.

### 3.2 Shelf (image 05)

Left and right: 280 pt wide, 64 pt cards, full height of the visible frame. Bottom: 140 pt strip, 112 pt cards. Menu-bar placement: 280 pt wide panel under the status item. Two sections: Pinned (up to 20) and Recent (20). Drop highlight uses the system accent colour (`NSColor.controlAccentColor`) so it respects the user's Mac setting. Sticky Shelf shows a close button (top right, 24 pt). Non-sticky Shelf dismisses on outside click or Esc.

### 3.3 Settings (image 06)

Toolbar window, 560 wide, height fits the pane. Panes in order: General, Shortcuts, Triggers, Privacy, Storage, About. Changes apply immediately (no Apply button); the window reopens on the last pane. Destructive actions (Clear History, shorten retention, reset ignored apps) use alerts (§4).

### 3.4 Onboarding (image 07)

Window 560x420, 8 steps, progress dots, every step skippable ("Skip"); Back and Continue at the bottom. Permission steps show what the user loses by skipping, in plain words, never as pressure. Step 4 (Input Monitoring) defaults to "Not Now".

### 3.5 Menu-bar and feedback (image 08)

Menu order: Open Library, Open Shelf, Pause Recording, Notices, separator, Settings, About Flotsam, Quit Flotsam. Notices submenu lists up to 10 entries (message and code) and "Dismiss All". HUD: top-centre of the pointer's screen, 2.5 s, non-activating (never steals focus), announced by VoiceOver.

Menu-bar glyph (template image, 18 pt, adapts to the menu-bar tint). Shape differs per state so colour is never the only cue (WCAG 1.4.1):

| State | Glyph | Accessibility label |
|---|---|---|
| Active | tilted plank over a wave | Flotsam, recording |
| Paused | two pause bars | Flotsam, paused |
| Curated | dashed plank over a wave | Flotsam, recording pinned items only |
| Warning | active glyph plus a dot | Flotsam, recording, needs attention |

## 4. Components and states

| Component | Default | Hover | Pressed | Focused | Disabled | Selected |
|---|---|---|---|---|---|---|
| Button | `bg-raised`, `edge` border | +4% `t1` | +8% `t1` | `focus` ring | `t3` text, 50% border | n/a |
| Primary button | `accent` fill, `on-sel` text | lighter 4% | darker 6% | ring | `sep` fill, `t3` | n/a |
| Destructive button | `err` text on raised; confirm alerts only | as button | as button | ring | as button | n/a |
| Search field | `bg-field`, `edge` | same | same | `focus` ring | n/a | n/a |
| List row | clear | `accent-tint` | n/a | ring on key focus | n/a | `sel` fill, `on-sel` text |
| Sidebar row | clear | `accent-tint` | n/a | ring | n/a | `accent-tint`, `accent-text` |
| Tag chip | `bg-raised`, dot + name | n/a | n/a | ring | n/a | n/a |
| Switch / checkbox | system control | system | system | system | system | system |

Alerts (NSAlert, sheet-style, max width 320): title at most 40, message at most 150, primary action on the right, Cancel left, destructive primary uses the destructive role (HIG: Alerts). Delete and Delete Items are never the default button when data loss is permanent; Cancel holds Return and Esc.

Popovers (tags, note, shortcut and trigger editor) anchor to the selected row, close on Esc, and return focus to the row.

## 5. States matrix

Empty (images 02, 05), no results (02), inline error with Retry (02, STO-DB-004), copy-only (02), multi-select (02), over-limit note (03), shortcut conflict (03), Missing item (01 grid), drop highlight (05), Pause (08), warning dot (08), fatal alert (08). Loading is not designed: all reads are local and under 50 ms; a read that takes longer shows the inline error.

## 6. Keyboard map (FR-003-08)

| Key | Action |
|---|---|
| Printable | types in search (always) |
| ↑ ↓ | move selection |
| ⌘↑ ⌘↓ | first / last |
| ⇧↑ ⇧↓ | extend selection |
| Return | paste |
| ⌥Return | paste as plain text |
| ⇧Return | copy only |
| ⌘1 to ⌘9 | quick paste row n |
| Space (empty search) or ⌘Y | preview |
| Esc | first press that applies: clear search if non-empty; else close preview if open; else, with several rows selected, reduce to one row; else close panel |
| ⌥↑ ⌥↓ | previous / next sidebar filter |
| ⌘G | toggle list and grid |
| ⌘R | reveal in Finder |
| ⌘P | pin / unpin |
| ⌘T | tags |
| ⌘N | note |
| ⌘E | edit text |
| ⌘⌫ | delete |
| ⌘S | cycle sort (Recent, Oldest, Most Used, A to Z) |
| ⌘⇧U | ungroup bundle |
| ⌘K | shortcut and trigger editor |
| ⌘, | Settings |

Tab moves between search, sidebar, results and preview; Full Keyboard Access reaches every button (WCAG 2.1.1).

## 7. Context menus

Library (FR-003-22): Paste, Paste as Plain Text, Copy, Preview, separator, Pin or Unpin, Tags…, Note…, Edit… (text only), Shortcut and Trigger…, Ungroup (bundles only), separator, Reveal in Finder, separator, Delete.
Shelf: Paste, Paste as Plain Text, Copy, separator, Pin or Unpin, separator, Delete.
Sidebar tag row: Rename, Colour (8 swatches with names), Delete.
Sort control: four items, checkmark on the active one.

## 8. UI Inventory coverage

Each row names the element from the FRD §8 table, where it is designed, and its image.

| FRD | Element | Design | Image |
|---|---|---|---|
| 003 | Library panel, search field | §3.1 | 01 |
| 003 | Sidebar rows (types, tags, apps, pinned) | §3.1 | 01 |
| 003 | Result list rows, grid cells, view toggle | §3.1 | 01 |
| 003 | ⌘1 to ⌘9 badges, kind icon or thumbnail | §3.1 | 01 |
| 003 | Pin, trigger, Missing badges, tag chips (3 + "+n") | §3.1 | 01 |
| 003 | Preview pane with Show more | §3.1 | 01 |
| 003 | Footer hint bar, copy-only footer | §3.1 | 01, 02 |
| 003 | Empty and no-results states | §5, §10 | 02 |
| 003 | Inline error with Retry (STO-DB-004) | §5, §11 | 02 |
| 003 | Context menu, ⌘, to Settings, HUD | §7, §3.5 | 03, 08 |
| 004 | Pin badge, Pinned row | §3.1 | 01 |
| 004 | Tag popover, chips, sidebar tag rows, tag menu | §4, §7 | 03 |
| 004 | Delete-tag confirmation | §10 | 04 |
| 004 | Note popover with counter | §4 | 03 |
| 004 | Text editor, formatting-removed notice | §10 | 04 |
| 004 | Delete and ungroup confirmations | §10 | 04 |
| 004 | Sort control | §7 | 03 |
| 004 | Inline validation text | §11 | 08 |
| 005 | Shortcut and trigger editor, conflict | §4 | 03 |
| 005 | Shortcut recorder (Settings) | §3.3 | 06 |
| 006 | Shelf placements, cards, sections, drop, sticky, empty, menu | §3.2 | 05 |
| 007 | Storage pane, Clear History, shorten alerts | §3.3, §10 | 06 |
| 008 | Settings panes, reset-apps alert, licence sheet | §3.3 | 06 |
| 008 | Onboarding steps 1 to 8 | §3.4 | 07 |
| 000 | Notices submenu, HUD, fatal alert | §3.5, §11 | 08 |
| 001, 002 | No UI of their own; permission and folder errors surface through Notices and HUD | §11 | 08 |

## 9. SF Symbols

Mockups use SVG stand-ins. Shipped names:

| Use | Symbol |
|---|---|
| Search | `magnifyingglass` |
| Pinned | `pin` / `pin.fill` |
| Text | `text.alignleft` |
| Images | `photo` |
| Files | `doc` |
| Links | `link` |
| Screenshots | `camera.viewfinder` |
| Colours | `paintpalette` |
| Tag | `tag` |
| App | `app` |
| Trigger | `bolt` |
| List / grid | `list.bullet` / `square.grid.2x2` |
| Missing | `exclamationmark.triangle` |
| Reveal | `folder` |
| Delete | `trash` |
| Notes | `note.text` |
| Pause | `pause.fill` |
| Warning | `exclamationmark.triangle.fill` |
| Success | `checkmark.circle` |
| Settings panes | `gearshape`, `keyboard`, `bolt`, `hand.raised`, `internaldrive`, `info.circle` |

Each icon-only control carries an `accessibilityLabel` (below).

## 10. Copy

Limits: buttons 15, alert titles 40, alert messages 150, notifications and HUD 100. Counts are characters including spaces; `{x}` placeholders are counted as written and the longest expected value is checked. Active voice; no jargon. Each string is one entry in the String Catalog (no concatenation; plurals use catalogue variations). Catalogue keys carry the `ui.` prefix (`ui.btn.*`, `ui.library.*`); a key shown here without it is not in the catalogue yet.

Deliberate deviations from FRD text: confirmation strings use curly quotes. `storage.confirm.clear` uses "can’t" for the FRD's "can't". `btn.deleteN` is replaced by "Delete Items" because "Delete 212 Items" is 16 characters.

### Buttons

| Key | String | Count |
|---|---|---|
| `btn.paste` | Paste | (5/15) |
| `ui.btn.retry` | Retry | (5/15) |
| `btn.enablePasting` | Enable pasting | (14/15) |
| `ui.btn.clearSearch` | Clear Search | (12/15) |
| `btn.cancel` | Cancel | (6/15) |
| `btn.save` | Save | (4/15) |
| `btn.delete` | Delete | (6/15) |
| `btn.deleteTag` | Delete Tag | (10/15) |
| `btn.ungroup` | Ungroup | (7/15) |
| `btn.replace` | Replace | (7/15) |
| `btn.deleteAll` | Delete All | (10/15) |
| `btn.deleteN` | Delete Items | (12/15) |
| `btn.openSettings` | Open Settings | (13/15) |
| `btn.resetDefaults` | Reset Defaults | (14/15) |
| `btn.chooseFolder` | Choose Folder… | (14/15) |
| `btn.getStarted` | Get Started | (11/15) |
| `btn.skipSetup` | Skip Setup | (10/15) |
| `btn.notNow` | Not Now | (7/15) |
| `btn.skip` | Skip | (4/15) |
| `btn.back` | Back | (4/15) |
| `btn.continue` | Continue | (8/15) |
| `btn.openLibrary` | Open Library | (12/15) |
| `btn.viewSource` | View Source | (11/15) |
| `btn.licence` | Licence | (7/15) |
| `btn.diagnostics` | Diagnostics | (11/15) |
| `btn.quit` | Quit Flotsam | (12/15) |
| `btn.done` | Done | (4/15) |
| `btn.clearHistory` | Clear History… | (14/15) |

### Library

| Key | String | Count |
|---|---|---|
| `ui.library.panelTitle` | Flotsam Library | (15/40) |
| `ui.library.searchPlaceholder` | Search clipboard history | (24/40) |
| `ui.library.emptyTitle` | Nothing copied yet | (18/40) |
| `ui.library.emptyBody` | Copy something and it appears here. Press ⌃⌘V any time to open this panel. | (74/150) |
| `ui.library.noResultsTitle` | No matches for “%@” | (24/40) |
| `ui.library.noResultsBody` | Check the spelling, or clear the search to see everything. | (58/150) |
| `ui.library.errorTitle` | History unavailable | (19/40) |
| `ui.library.footerCopyOnly` | Press ⌘V to paste | (17/40) |
| `ui.library.footerMultiDisabled` | Select one item to paste | (24/40) |
| `ui.library.footerItems` | 1 item / %lld items (plural: one, other) | (9/40) |
| `ui.library.footerSelected` | %lld selected | (12/40) |
| `ui.library.hintPaste` | Paste | (5/15) |
| `ui.library.hintPlain` | Plain text | (10/15) |
| `ui.library.hintCopy` | Copy | (4/15) |
| `ui.library.hintPreview` | Preview | (7/15) |
| `ui.library.hintClose` | Close | (5/15) |
| `ui.library.hintClearSelection` | Clear selection | (15/15) |
| `ui.library.keyReturn`, `keyOptionReturn`, `keyShiftReturn`, `keySpace`, `keyEsc` | Return, ⌥Return, ⇧Return, Space, Esc | (footer key caps) |
| `ui.library.sidebarAll`, `sidebarPinned` | All, Pinned | (3/15, 6/15) |
| `ui.library.sectionTypes`, `sectionTags`, `sectionApps` | Types, Tags, Apps | (5/15, 4/15, 4/15) |
| `ui.library.appAnotherDevice`, `appUnknown` | Another device, Unknown | (14/15, 7/15) |
| `ui.library.typeText` to `typeScreenshot` | Text, Rich Text, Links, Colors, Phone Numbers, Emails, Images, Files, Folders, Bundles, Screenshots | (sidebar type names) |
| `ui.library.tagOverflow` | +%lld | (row chips) |
| `ui.library.fromApp` | from %@ | (VoiceOver row label) |
| `ui.library.spokenPinned` | pinned | (VoiceOver row label, pinned rows) |
| `ui.library.previewShowMore` | Show more | (9/15) |
| `ui.library.previewMore` | and %lld more | (13/40) |
| `ui.library.previewUnavailable` | Preview unavailable | (19/40) |
| `ui.library.previewKind` | Kind | (4/15) |
| `ui.library.previewSource` | Source | (6/15) |
| `ui.library.previewCopied` | Copied | (6/15) |
| `ui.library.previewTimesPasted` | Times pasted | (12/15) |
| `ui.library.previewSize` | Size | (4/15) |
| `ui.library.previewPixelSize` | Pixel size | (10/15) |
| `ui.library.menuPaste`, `menuPastePlain`, `menuCopy`, `menuPreview`, `menuReveal` | Paste, Paste as Plain Text, Copy, Preview, Reveal in Finder | (context menu, FR-003-22) |
| `ui.library.viewGrid`, `viewList` | Grid view, List view | (view toggle VoiceOver label) |
| `library.sort.recent` | Recent | (6/15) |
| `library.sort.oldest` | Oldest | (6/15) |
| `library.sort.mostUsed` | Most Used | (9/15) |
| `library.sort.az` | A to Z | (6/15) |
| `library.preview.firstCopied` | First copied | (12/15) |
| `library.preview.timesCopied` | Times copied | (12/15) |

### Organize

| Key | String | Count |
|---|---|---|
| `organize.confirm.deleteTag.title` | Delete tag “{name}”? | (20/40) |
| `ui.organize.confirmDeleteTag` | Remove tag '{name}' from 1 item? / from {n} items? (plural: one, other) | (49/150) |
| `organize.confirm.delete.title` | Delete this item? | (17/40) |
| `ui.organize.confirmDelete` | Delete {n} items permanently? This cannot be undone. (plural: one, other; one item uses `ui.organize.confirmDeleteOne`: Delete this item permanently? This cannot be undone.) | (53/150) |
| `organize.confirm.ungroup.title` | Ungroup {n} items? | (18/40) |
| `organize.confirm.ungroup` | They become separate items in your history. | (43/150) |
| `organize.edit.formattingRemoved` | Saving removes formatting. The edited item becomes plain text. | (62/150) |
| `organize.tag.create` | Create “{name}” | (15/40) |
| `organize.tag.mixed` | {k} of {n} | (10/15) |
| `organize.note.counter` | {n} / 1,000 | (11/15) |
| `organize.trigger.help` | Triggers fire when you type the text followed by a space. Variables: {date}, {time}, {clipboard}. | (97/150) |

### Settings

| Key | String | Count |
|---|---|---|
| `settings.confirm.resetIgnored.title` | Reset ignored apps? | (19/40) |
| `settings.confirm.resetIgnored` | Replace your list with the default apps? | (40/150) |
| `storage.confirm.shorten.title` | Shorten history? | (16/40) |
| `ui.settings.confirmShorten` | This permanently deletes {n} item(s) older than {period}. Pinned items and items with a shortcut are kept. (plural: one, other) | (104/150) |
| `storage.confirm.clear.title` | Clear all history? | (18/40) |
| `ui.settings.clearCount` | This permanently deletes {n} item(s). This can’t be undone. (plural: one, other) | (57/150) |
| `ui.settings.clearDone` | {n} item(s) deleted (plural: one, other) | (15/40) |
| `ui.settings.confirmBudget` | Lowering the image budget removes {n} older image(s) ({size}). Pinned and shortcut items are kept. (plural: one, other) | (90/150) |
| `ui.row.bundleCount` | 1 item / {n} items (plural: one, other) | (7/40) |
| `settings.privacy.accessibility.help` | Lets Flotsam paste into the app you are using. | (46/150) |
| `settings.privacy.input.help` | Lets triggers notice the text you type. Flotsam never stores keystrokes. | (72/150) |
| `settings.privacy.pasteOther.help` | macOS 15.4 and later asks before apps read the clipboard. Choose Always Allow. | (78/150) |
| `settings.triggers.needInput` | Triggers need Input Monitoring. Open Settings to allow it. | (58/150) |
| `settings.storage.keepHelp` | Pinned items and items with a shortcut are always kept. | (55/150) |
| `settings.general.historyHelp` | Turn off to pause. Existing items stay. | (39/150) |
| `settings.shortcuts.recording` | Press the keys you want. Esc cancels. | (37/150) |
| `settings.about.tagline` | Free, open source clipboard history. Everything stays on your Mac. | (66/150) |

### Onboarding

| Key | String | Count |
|---|---|---|
| `onb.1.title` | Everything you copy, within reach | (33/40) |
| `onb.1.body` | Flotsam keeps your clipboard and screenshot history on this Mac. Nothing leaves it. | (83/150) |
| `onb.2.title` | Allow Paste from Other Apps | (27/40) |
| `onb.2.body` | macOS 15.4 and later asks before apps read the clipboard. Choose Always Allow so Flotsam can save what you copy. | (112/150) |
| `onb.2.stakes` | Skip this and Flotsam can’t record new copies. | (46/150) |
| `onb.3.title` | Allow Accessibility | (19/40) |
| `onb.3.body` | Accessibility lets Flotsam paste into the app you are using. | (60/150) |
| `onb.3.stakes` | Skip this and Flotsam copies only. You press ⌘V yourself. | (57/150) |
| `onb.4.title` | Add triggers (optional) | (23/40) |
| `onb.4.body` | Input Monitoring lets Flotsam notice the text you type to expand triggers. It never stores keystrokes. | (102/150) |
| `onb.4.stakes` | You can turn this on later in Settings. | (39/150) |
| `onb.5.title` | Pick up screenshots | (19/40) |
| `onb.5.body` | Choose the folder where macOS saves screenshots. Flotsam adds new ones to your history. | (87/150) |
| `onb.6.title` | Open Library with a shortcut | (28/40) |
| `onb.6.body` | Press this shortcut any time to search your history. | (52/150) |
| `onb.7.title` | Open Flotsam at login | (21/40) |
| `onb.7.body` | Flotsam stays in the menu bar so your history is always ready. | (62/150) |
| `onb.8.title` | You’re ready | (12/40) |
| `onb.8.body` | Copy something, then press ⌃⌘V. Flotsam lives in your menu bar. | (63/150) |

### Shelf

| Key | String | Count |
|---|---|---|
| `ui.shelf.empty` | Shelf is empty. Copy something, or drag an item here to pin it. | (63/150) |
| `ui.shelf.drop` | Drop to pin | (11/15) |
| `ui.shelf.sectionRecent` | Recent | (6/15) |

The Pinned section label reuses `ui.library.pinned` (Library table).

### Feedback

| Key | String | Count |
|---|---|---|
| `hud.pasted` | Pasted “{preview}” | (18/100) |
| `hud.paused` | Recording paused | (16/100) |
| `hud.copyOnly` | Pasting is off. Press ⌘V to paste. | (34/100) |
| `hud.clipboardFail` | Couldn’t read the clipboard. Copy it again. | (43/100) |
| `notice.shotSave` | Couldn’t save a screenshot | (26/100) |
| `notice.pasteOff` | Pasting is off. Flotsam copies only. | (36/100) |
| `fatal.title` | Flotsam can’t open its history | (30/40) |

### Menus

| Key | String | Count |
|---|---|---|
| `menu.openLibrary` | Open Library | (12/15) |
| `menu.openShelf` | Open Shelf | (10/15) |
| `menu.pause` | Pause Recording | (15/15) |
| `menu.resume` | Resume | (6/15) |
| `menu.notices` | Notices | (7/15) |
| `menu.dismissAll` | Dismiss All | (11/15) |
| `menu.settings` | Settings… | (9/15) |
| `menu.about` | About Flotsam | (13/15) |
| `menu.quit` | Quit Flotsam | (12/15) |



## 11. Errors

Message copy lives once, in FRD-000 §Catalogue (Rule 9: single source). Design adds only presentation, all messages at most 140 characters (longest: STO-DB-003, 129/140):

| Class | Presentation |
|---|---|
| Error from a user action | inline text in the surface (icon `exclamationmark.triangle.fill`, colour `err`, message and code in `t2`) |
| Warning, background | Notice (menu-bar submenu, warning dot on glyph) |
| Transient result | HUD, at most 100 characters |
| Fatal (STO-DB-003, STO-IO-002) | alert with "Quit Flotsam" and "Show Folder" |
| Info | no UI |

Fatal alert title: "Flotsam can’t open its history" (30/40). Library inline error title for STO-DB-004: "History unavailable" (19/40), body from the catalogue, button "Retry" (5/15). Inline validation pairs a symbol with text so colour is not the only cue (WCAG 1.4.1).

## 12. VoiceOver labels

| Element | Label | Hint or value |
|---|---|---|
| Search field | Search clipboard history | |
| Result row | kind, preview, source app, age | "pinned", "has shortcut", "missing" appended as traits |
| Grid cell | same as row | |
| Pin badge | Pinned | |
| Trigger badge | Has trigger | |
| Missing badge | Original file missing | |
| Tag chip | Tag, {name} | |
| View toggle | List view / Grid view | selected state |
| Sort control | Sort by {sort} | |
| Quick-paste badge | Command {n} | decorative on the row; row action named "Paste" |
| Shelf card | same as row | |
| Shelf close | Close Shelf | |
| Menu-bar item | per §3.5 | |
| HUD | message text | posted as an announcement |
| Onboarding dots | Step {n} of 8 | |

Order follows reading order: search, sidebar, results, preview, footer. Selection changes announce the new row. Esc closes with focus returning to the invoking app.

## 13. Not applicable

No Dock icon (LSUIElement). No tab bar, no iOS sheets, no Dynamic Type (macOS), no custom window chrome, no account or sign-in UI, no analytics or consent UI (anti-truths A1, A4), no ratings prompt, no streaks, no badges, no time-limited offers. 44 pt rule: macOS pointer UI follows HIG control sizes; 44 pt is kept for list rows, Shelf cards and onboarding buttons.

## 14. Truth test

All surfaces serve truths in `docs/TRUTHS.md`: local-first (no network, no accounts), keyboard speed, free and open. Nothing here asks for CUT or ESCALATE; no manipulation mechanic exists. Manipulation test passed: every mechanic can be explained to the user as-is.
