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
| Library | floating NSPanel, 760x480 (min 560x360); Compact layout 520x520 (min 480x400) | 01, 02, 03, 04 |
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
| `sel` | accent mixed 30% toward light grey (0.8), then 65% toward white | accent mixed 35% toward mid-dark grey (0.3), then 30% to 70% toward black (the least that leaves `on-sel-2` at 4.5:1) | selected result row and pill fill: opaque, derived from the system accent and muted toward grey so it does not out-shout the search field (`DesignToken.selectionFill`); hill-climb r3, r4, r5 |
| `sel-side` | primary at 12% | primary at 12% | the sidebar's selected row: a neutral wash with the primary label (`DesignToken.sidebarSelection`); hill-climb r4 |
| `on-sel` / `on-sel-2` | primary label / primary at 82% | primary label / primary at 82% | text on `sel` (`on-sel-2` is `DesignToken.onSelectionSecondary`; never `.secondary`, which fades into the fill) |
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

Type cues (hill-climb r5, TASK-529): the colour of a Shelf card's 3 pt top edge and of its kind icon, so a column of cards reads by type before it is read. One function, `DesignToken.typeCue(for:)`, returns system colours (so they follow appearance and the user's contrast settings): text gray, rich text indigo, link blue, colour pink, phone green, email teal, image purple, file orange, folder brown, bundle yellow, screenshot cyan. Decoration only (WCAG 1.4.1): the icon and the card text always say the type as well, so no contrast is asked of the edge.

### 2.2 Contrast (computed, OKLCH to sRGB, WCAG 2.x)

| Pair | Light | Dark | Need |
|---|---|---|---|
| t1 on bg | 16.10 | 14.83 | 4.5 (1.4.3) |
| t2 on bg | 6.62 | 8.33 | 4.5 |
| t3 on bg | 4.91 | 6.01 | 4.5 |
| t3 on bg-side | 4.56 | 6.46 | 4.5 |
| accent-text on bg-side | 4.73 | 8.72 | 4.5 |
| on-sel on sel (default blue accent, computed) | 9.76 | 8.11 | 4.5 |
| on-sel-2 on sel (default blue accent, computed) | 9.10 | 7.65 | 4.5 |
| edge on bg | 3.13 | 3.89 | 3 (1.4.11) |
| edge on bg-field | 3.36 | 4.31 | 3 |
| focus on bg | 3.15 | 8.64 | 3 (1.4.11, 2.4.7) |

The selection tone (hill-climb r3, TASK-529): `sel` is the user's system accent, opaque, so the contrast of a selected row's text does not depend on what is behind the translucent panel; it is the accent mixed 60% toward white in light, and in dark the accent mixed toward black by the least amount (30% to 70%, in 5% steps) that leaves `on-sel-2` 4.5:1 on it. In dark that keeps a blue accent at the button blue's hue and only darkens a light accent as far as its text needs: re-measured in round 4 (hill-climb r4, TASK-529) for the eight system accents (Multicolour follows Blue) with the dark accent values, the fill is 40% toward black for Blue, Purple, Pink and Red, 45% for Graphite, 55% for Orange and Green and 65% for Yellow, and the primary label measures 6.0 to 6.8 and `on-sel-2` 4.55 to 5.16 on them; in light the primary label measures 9.7 to 13.4 and `on-sel-2` 6.4 to 7.9. This closes the r3 shortfall (Yellow in dark measured 4.49 and 4.30 on the fixed 50% fill). The accent fills one surface only: the selected result row. The sidebar's selected row is a neutral wash (the primary colour at 12%, `DesignToken.sidebarSelection`) with the primary label, so the panel shows one accent fill, not two; the type pills keep `sel` because they are controls, and buttons, toggles and the row use the one accent hue. A selected row's tag chips use the primary label over a stronger wash. The hover and keyboard-cursor wash on an unselected row is the primary colour at 8% (`DesignToken.cursorFill`).

Measured in hill-climb r5 (TASK-529; the Library panel's material and tint are unchanged in r5, so the panel samples are the round-4 screenshots, 14 pixels over the list, sidebar and search strip; the labels are the system primary at 85% and secondary at 50% (light) and 55% (dark) alpha, WCAG 2.x, composited over the sampled pixel). Selected row, all eight system accents with the r5 muted `sel` (computed from the same formula as `DesignToken.selectionFill`): light primary 11.24 to 13.38 and `on-sel-2` 7.06 to 7.85; dark primary 5.97 to 6.43 and `on-sel-2` 4.59 to 4.93 (the dark fill is the accent 35% toward grey, then 30% (Blue, Purple, Pink), 35% (Red), 40% (Graphite), 50% (Orange, Green) or 60% (Yellow) toward black). All 16 pairs clear 4.5:1. Panel text over the bare `.hudWindow` material: the primary label 12.40 to 15.08 in light and 6.00 to 8.44 in dark. **The system secondary label does not reach 4.5:1 on the bare material: 3.78 to 3.98 in light, 3.55 to 4.55 in dark (the dark low is the strip under the title)**, because it is the system's own colour over a translucent surface. This is a known shortfall against the 4.5:1 target (WCAG 1.4.3), not met by the r5 build; closing it means a raised secondary-text token for the panel, which is a design decision still open (reported, TASK-529). Anywhere a label must be read (selected row, buttons, field text) it uses `on-sel-2`, the primary label or an opaque surface, which clear the target above.

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

Spacing: 2, 4, 8, 12, 16, 20, 24 pt. Radii: panel 16, popover 12, card 10, row 8, control 6, chip 6; these are exactly `DesignToken.Radius` in `App/Flotsam/DesignTokens.swift` and nothing in the app draws a radius off the scale (hill-climb r3). Shadows: `shadow-panel`, `shadow-pop` (dark adds a 0.5 pt light edge so panels separate on dark desktops). Materials: Library and Shelf use the `.hudWindow` NSVisualEffectView, and popovers the `.popover` material; Settings and alerts use opaque `bg`. Corrected in hill-climb r5 (TASK-529): earlier versions of this section said the panels carry `bg` at 0.82 alpha over the material; the code never draws that layer, the panel is the bare material, and the Library's `library.background` setting (FR-003-21, FRD-008) forces the material light or dark or follows the system, so the panel's look follows the user's appearance choice and not a second default tint. **Tint rule (r5): any tint laid over the material is capped at 0.6 alpha, so the material always shows through; nothing in the app hides it.** The one tint the Shelf draws is a lift, not a second tint: in light appearance a faint white wash over its material (30% at the top fading to 6% at the bottom; none in dark appearance, where the material already reads as a surface), which adds no hue and leaves the material and its radius as they are (hill-climb r4). Hairlines: the one line between two regions is `Hairline`, the system separator colour at one device pixel (never a heavier custom line). The end fade: a scroller's last edge dissolves to clear over `DesignToken.endFadeHeight`, 36 pt (one 24 pt row plus 8 pt), with a bottom content margin of the same height so the last row scrolls clear of it; the Library sidebar, the Library grid and the Shelf list all use it, and only while their content is taller than the viewport (hill-climb r5; the sidebar's own fade was 24 pt).

### 2.5 Motion

Library appears in 120 ms ease-out (scale 0.98 to 1, fade). Shelf slides 150 ms in, 120 ms out. HUD fades 120 ms. Reduce Motion on: every transition becomes a 100 ms cross-fade, no scale, no slide (HIG: Motion; WCAG 2.3.3). No looping or decorative animation anywhere.

### 2.6 Accessibility fallbacks

- Reduce Transparency: material becomes opaque `bg` / `bg-side`.
- Increase Contrast: `sep` becomes `edge`; `t3` becomes `t2`; selection adds a 2 pt `focus` inner ring.
- Hit targets: pointer controls are at least 24x24 pt with 44 pt row height in lists (macOS pointer; WCAG 2.5.8; the 44 pt target applies to Shelf cards and onboarding buttons).
- Focus is always visible: 2 pt `focus` ring, 2 pt offset (WCAG 2.4.7, 2.4.11).

## 3. Layouts

### 3.1 Library (images 01 to 04)

760x480, centred on the pointer's screen, resizable to 560x360 minimum. Three columns: sidebar 184, results taking the remaining width, preview 280 by default (200 to 360 as the panel is resized). No column collapses at narrow widths: the panel's 560 pt minimum is the narrowest, and at that width the sidebar and the results list stay visible with the preview open (FR-003-03). Search field 36 pt at top. Footer hint bar 30 pt.

Compact layout (FR-003-06, Settings > Library): two columns, sidebar 184 and results, no preview column, 520x520 (min 480x400). Space or ⌘Y shows the preview in place of the results with the sidebar kept; Esc returns to the list. Tab order and VoiceOver order: search, sidebar, results (or the preview).

- Sidebar sections: Library (All, Pinned), Types (Text, Images, Files, Links, Screenshots, Colours), Tags, Apps. Rows and section headers are each one 24 pt line with 13 pt row text (tight, so the results list stays the dominant column), count right-aligned. Each row leads with a 12 pt SF Symbol; labels are secondary and counts tertiary; the selected row is primary on the neutral `sel-side` wash with the row radius (FR-003-12). The sidebar is 184 pt wide so "Phone Numbers" and the other type names of FRD-002 show whole, not cut to "Phone Numb…"; its bottom edge fades over the shared end fade (36 pt, §2.4) while it scrolls, so a row is never cut mid-glyph at 760x480. The sidebar's viewport is a whole number of lines (plus a 4 pt top margin) and scrolls line by line, so its bottom edge never cuts a row (FR-003-07).
- List rows: 44 pt, a 32 pt lead: an image's thumbnail, a colour's swatch, otherwise the source app's own icon (20 pt, from the stored bundle ID, cached, no network), falling back to the kind glyph when there is no source or the app is no longer installed (FR-003-07), first line `t1` single line, second line `t2` (source app, age); the title truncates by the width left, a hovered row reserves 94 pt for its strip and its own badges give way, and the selected row is the `sel` fill with `on-sel-2` secondary text. The list's viewport is a whole number of rows (a gap of at least 2 pt, a 4 pt top margin, scroll snapped to a row), so its bottom edge never cuts a row and it needs no fade (FR-003-07). Badges: pin, trigger, Missing (warn). Up to 3 tag chips then "+n". Quick-paste badge ⌘1 to ⌘9 on the first nine rows.
- Grid cells: 120 pt square, thumbnail, name caption, same badges.
- Preview: a compact metadata header directly under the top edge (hill-climb r5; it was a footer at the bottom, which left a short snippet floating over a gap): one secondary-colour line of kind, source app, copied time and size, separated by middle dots, a colour's values and the tags under it, every other field (first copied, times copied, pastes, pixel size, note) folded behind a chevron ("Show details" and "Hide details") and one-line label and value while open; the header is capped at 150 pt and scrolls inside itself past that; the content takes all the height that is left; "Show more" past 12 lines (text) or fit for images. Indented text (code) is monospaced, keeps its indentation, does not soft-wrap and scrolls sideways with a 24 pt fade at the trailing edge while it overflows, so the cut reads as intentional (FR-003-14).
- Footer: the same four key hints in every state, in this order (Return Paste, Space Preview ("Space Close Preview" while the preview is showing), ⌥Return Plain Text, Esc Close; ⌘C Copy replaces Plain Text while pasting is off), while the list has nothing to act on (an empty history, a search with no results) only Esc Close is shown and the sort name and count are hidden, never "Recent 0 items" (FR-003-18); with rows, the active sort name (Recent, Oldest, Most Used, A to Z) beside the item count at the right; copy-only mode shows "Press ⌘V to paste" and an "Enable pasting" link.

### 3.2 Shelf (image 05)

Left and right: 280 pt wide, 96 pt cards (header row: source app icon, name, age; content below), full height of the visible frame. Bottom: 140 pt strip, 144 pt cards. Menu-bar placement: 280 pt wide panel under the status item. Cards use the card radius (10) and a 16 pt source icon; in the vertical placements a text card is as tall as its measured text (never under two lines of text plus its header, `ShelfLayout.textCardMinimumLines`; never over 96; hill-climb r5 raised the floor from a flat 48 pt, which fitted one line), not a fixed height, and its text is drawn as whole lines only (three at the card font size) with the last line faded when the text goes on (hill-climb r4). Every card has a 3 pt top edge and a kind icon in the kind's type cue colour (§2.1). An image or screenshot card is full-bleed: the picture runs edge to edge, clipped to the card's corners, with its header on a scrim (white on 60% black); every other kind keeps its content below the header (hill-climb r5). The Pinned and Recent section headers are semibold caption text in sentence case in secondary colour and carry the header trait for VoiceOver, so the two groups read apart by weight, as the system draws a section header (r5; r4 had upper-case, tracked). The vertical list ends in the shared end fade (§2.4) while it scrolls. The type pills in the search header are drawn whole: those that fit are shown and the rest go in a "More" menu, and the selected pill uses the `sel` fill (FR-006-22). Two sections: Pinned (up to 20) and Recent (20). Drop highlight uses the system accent colour (`NSColor.controlAccentColor`) so it respects the user's Mac setting. Sticky Shelf shows a close button (top right, 24 pt). Non-sticky Shelf dismisses on outside click or Esc.

### 3.3 Settings (image 06)

Toolbar window, 560 wide, height fits the pane. Panes in order: General, Library, Shortcuts, Types, Triggers, Privacy, Storage, Tips, About. The General pane is one grouped form with a header per group (System, Screenshots, Shelf) and each control's note directly under its label, at the native 13 pt row height (FRD-008 FR-008-04); the Library pane holds the Library and Capture groups (FR-008-33). No pane is built taller than a laptop screen: a pane that would be is split by topic, because a scrolling viewport's edge can cut a row. A button is never alone in a row: it sits in a labelled row (label leading, button trailing, as "Setup guide", "Login items" and "Recent screenshots" do), and a caption that only restates its label is removed (hill-climb r5). Controls are the native ones: the system switch, the native menu pop-up and the native bordered button, with no custom chip styling. The nine toolbar tabs share one symbol weight and scale. Editable fields outside a grouped form (the Library search, the shortcut recorder, the trigger field) are a text-field surface with the control-edge border in light and a lifted light wash with a hairline border in dark, so they read as fields on the panel in both. Shortcut rows use the shared recorder field: keycap glyphs, "Click to Record Shortcut" when empty, a focus ring while it has keyboard focus or is recording, an inline clear button (FR-008-05). In the item editor the Shortcut and Trigger fields share one height (`FieldMetric.height`, 28 pt) and one fill, and the (?) and clear buttons are one glyph style (`AccessoryGlyphButtonStyle`: 15 pt, secondary colour, 20 pt target); the clip's text above them wraps to two lines and ends at a word boundary (FR-005-09). Changes apply immediately (no Apply button); the window reopens on the last pane. Destructive actions (Clear History, shorten retention, reset ignored apps) use alerts (§4).

### 3.4 Onboarding (image 07)

Window 560x420, 8 steps, 8 pt progress dots centred above the title, every step skippable ("Skip", alone at the far leading edge, as in a macOS assistant); Back and Continue together at the trailing edge; the heading centred in the window and the titlebar transparent so the background runs under it (hill-climb r5). Permission steps (2 to 4) share one centred layout: a 64 pt permission symbol, title and purpose, then what the user loses by skipping, in plain words, never as pressure; once the permission is granted a green check symbol and one confirmation line in the label colour replace that warning, Continue becomes the single prominent button, and the skip action is a plain text button (FR-008-12). Step 4 (Input Monitoring) defaults to "Not Now" until it is granted.

### 3.5 Menu-bar and feedback (image 08)

Menu order: Open Library, Save Clipboard to Library, New Clip from Text…, Toggle Shelf, separator, Pause Capture (a submenu while Active) or Resume Capture (while Paused or Curated), Clear Recent, Warnings and Errors, separator, Settings…, Show Setup Guide…, separator, Quit Flotsam (FR-008-16). The Warnings and Errors submenu (named for what it lists, the FRD-000 Notices of level Warning or Error; "No Warnings or Errors" when empty; hill-climb r5) lists up to 10 entries (message and code) and "Dismiss All". While capture is paused a disabled line above Resume Capture reads "Paused until {time}" or "Paused until you resume". HUD: top-centre of the pointer's screen, 2.5 s, non-activating (never steals focus), announced by VoiceOver.

Menu-bar glyph (template image, 18 pt, adapts to the menu-bar tint). Shape differs per state so colour is never the only cue (WCAG 1.4.1):

| State | Glyph | Accessibility label |
|---|---|---|
| Active | tilted plank over a wave | Flotsam, capturing |
| Paused | two pause bars | Flotsam, capture paused |
| Curated | dashed plank over a wave | Flotsam, curated capture |
| Warning | active glyph plus a dot | the mode's label, then Needs attention |

## 4. Components and states

| Component | Default | Hover | Pressed | Focused | Disabled | Selected |
|---|---|---|---|---|---|---|
| Button | `bg-raised`, `edge` border | +4% `t1` | +8% `t1` | `focus` ring | `t3` text, 50% border | n/a |
| Primary button | `accent` fill, `on-sel` text | lighter 4% | darker 6% | ring | `sep` fill, `t3` | n/a |
| Destructive button | `err` text on raised; confirm alerts only | as button | as button | ring | as button | n/a |
| Search field | `bg-field`, `edge` | same | same | `focus` ring | n/a | n/a |
| List row | clear | primary 8% (`cursorFill`) | n/a | ring on key focus | n/a | `sel` fill, `on-sel` text, `on-sel-2` secondary |
| Sidebar row | clear | primary 8% (`cursorFill`) | n/a | ring | n/a | `sel` fill, primary label and symbol, `on-sel-2` count |
| Tag chip | `bg-raised`, dot + name | n/a | n/a | ring | n/a | n/a |
| Switch / checkbox | system control | system | system | system | system | system |

Alerts (NSAlert, sheet-style, max width 320): title at most 40, message at most 150, primary action on the right, Cancel left, destructive primary uses the destructive role (HIG: Alerts). Delete and Delete Items are never the default button when data loss is permanent; Cancel holds Return and Esc.

Popovers (tags, note) anchor to the selected row, close on Esc, and return focus to the row. The shortcut and trigger editor is a small titled window instead (FRD-005 §8): centred, one at a time, closes on Esc or ⌘W; a two-column aligned form (labels, then the shared shortcut recorder field with keycaps and inline clear, and the trigger field), titled "Edit Shortcut", with the clip name as a middle-truncated subtitle line inside the form and one short help line under the trigger field; both fields are 28 pt high; Save is the default button and Cancel answers Esc.

## 5. States matrix

Empty (images 02, 05), no results (02), inline error with Retry (02, STO-DB-004), copy-only (02), multi-select (02), over-limit note (03), shortcut conflict (03), Missing item (01 grid), drop highlight (05), Pause (08), warning dot (08), fatal alert (08). Loading and searching (Library FR-003-50, Shelf FR-006-32) and empty tag (Library FR-003-50) complete the matrix.

| State | Where | Shown | Never shown |
|---|---|---|---|
| Loading | Library results area, Shelf panel | blank for the first 150 ms; from 150 ms a small spinner and `ui.library.loading`, centred, until the read ends | for a read under 150 ms; the empty or no-matches text while the read runs |
| Searching | same | as Loading with `ui.library.searching` while the search field has text or a Shelf pill is chosen; over rows already on screen the rows stay and the spinner is a badge at the top | for a search under 150 ms |
| Empty tag | Library results area | a tag chosen in the sidebar with no items and an empty search: `ui.library.emptyTagTitle` (the tag's name) and `ui.library.emptyTagBody` | with text in the search field (that is no results); in the Shelf, which has no tag filter |

The 150 ms is one constant (`BusyIndicator.delay`) shared by both panels, run as a single one-shot task cancelled when the read ends: no repeating timer and nothing armed while idle (truth S5). A read that fails shows the inline error with Retry, not the spinner.

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
| ⌘C | copy the selected item only (same as ⇧Return); copies the search field's text instead when it has a selection |
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

Library (FR-003-22): Paste, Paste as Plain Text, Copy, Preview, separator, Pin or Unpin, Tags…, Note…, Edit… (text only), Shortcut and Trigger… (one non-secure item only), Ungroup (bundles only), separator, Reveal in Finder, separator, Delete.
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
| 000 | Warnings and Errors submenu, HUD, fatal alert | §3.5, §11 | 08 |
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
| Settings panes | `gearshape`, `list.bullet.rectangle`, `keyboard`, `square.grid.2x2`, `bolt`, `hand.raised`, `internaldrive`, `lightbulb`, `info.circle` |

Each icon-only control carries an `accessibilityLabel` (below).

## 10. Copy

Limits: buttons 15, alert titles 40, alert messages 150, notifications and HUD 100. Counts are characters including spaces; `{x}` placeholders are counted as written and the longest expected value is checked. Active voice; no jargon. Each string is one entry in the String Catalog (no concatenation; plurals use catalogue variations). Catalogue keys carry the `ui.` prefix (`ui.btn.*`, `ui.library.*`); a key shown here without it is not in the catalogue yet.

Deliberate deviations from FRD text: confirmation strings use curly quotes. `storage.confirm.clear` uses "can’t" for the FRD's "can't". `btn.deleteN` is replaced by "Delete Items" because "Delete 212 Items" is 16 characters. "Open System Settings" is 20 characters, over the button limit of 15, and stays: FRD-008 FR-008-06 and FR-008-13 name the button, and it opens macOS System Settings, not Flotsam's own Settings window, so "Open Settings" would mislead.

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
| `ui.settings.openSystemSettings`, `ui.onboarding.openSystemSettings` | Open System Settings | (20/15) |
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
| `ui.library.emptyTagTitle` | Nothing tagged “%@” yet | (23/40) |
| `ui.library.emptyTagBody` | Tag a clip from its context menu, or choose All to see everything. | (66/150) |
| `ui.library.loading` | Loading… | (8/15) |
| `ui.library.searching` | Searching… | (10/15) |
| `ui.library.errorTitle` | History unavailable | (19/40) |
| `ui.library.footerCopyOnly` | Press ⌘V to paste | (17/40) |
| `ui.library.footerMultiDisabled` | Return queues these items | (24/40) |
| `ui.library.footerItems` | 1 item / %lld items (plural: one, other) | (9/40) |
| `ui.library.footerSelected` | %lld selected | (12/40) |
| `ui.library.hintPaste` | Paste | (5/15) |
| `ui.library.hintPlain` | Plain Text | (10/15) |
| `ui.library.hintCopy` | Copy | (4/15) |
| `ui.library.hintPreview` | Preview | (7/15) |
| `ui.library.hintClose` | Close | (5/15) |
| `ui.library.hintClearSelection` | Clear selection | (15/15) |
| `ui.library.keyReturn`, `keyOptionReturn`, `keyCommandC`, `keySpace`, `keyEsc` | Return, ⌥Return, ⌘C, Space, Esc | (footer key caps) |
| `ui.library.sidebarAll`, `sidebarPinned`, `sidebarNotes`, `sidebarShortcuts`, `sidebarVideos` | All, Pinned, Notes, Shortcuts, Videos | (3/15, 6/15, 5/15, 9/15, 6/15) |
| `ui.library.sectionTypes`, `sectionTags`, `sectionApps` | Types, Tags, Apps | (5/15, 4/15, 4/15) |
| `ui.library.typesHide`, `typesShow` | Hide Types, Show Types | (tooltip and VoiceOver hint of the Types header, 10/40, 10/40) |
| `ui.library.appAnotherDevice`, `appUnknown` | Another device, Unknown | (14/15, 7/15) |
| `ui.library.typeText` to `typeScreenshot` | Text, Rich Text, Links, Colors, Phone Numbers, Emails, Images, Files, Folders, Bundles, Screenshots | (sidebar type names) |
| `ui.library.tagOverflow` | +%lld | (row chips) |
| `ui.library.fromApp` | from %@ | (VoiceOver row label) |
| `ui.library.spokenPinned` | pinned | (VoiceOver row label, pinned rows) |
| `ui.library.spokenSecure` | Secure item | (VoiceOver row label, secure rows, in place of kind and text) |
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
| `settings.confirm.resetIgnored` | Clear the ignored-apps list? Flotsam will store copies from every app, password managers included. | (98/150) |
| `storage.confirm.shorten.title` | Shorten history? | (16/40) |
| `ui.settings.confirmShorten` | This permanently deletes {n} item(s) older than {period}. Pinned items and items with a shortcut are kept. (plural: one, other) | (104/150) |
| `storage.confirm.clear.title` | Clear all history? | (18/40) |
| `ui.settings.clearCount` | This permanently deletes {n} item(s). This can’t be undone. (plural: one, other) | (57/150) |
| `ui.settings.deleteAction` | Delete (confirm button of the shorten-history and lower-image-budget alerts) | (6/15) |
| `ui.settings.clearCounting` | Counting items… | (15/150) |
| `ui.settings.clearCountFailed` | Couldn’t count the items in this range. (shown when the count fails; Delete stays disabled) | (39/150) |
| `ui.settings.clearDone` | {n} item(s) deleted (plural: one, other) | (15/40) |
| `ui.settings.confirmBudget` | Lowering the image budget removes {n} older image(s) ({size}). Pinned and shortcut items are kept. (plural: one, other) | (90/150) |
| `ui.row.bundleCount` | 1 item / {n} items (plural: one, other) | (7/40) |
| `settings.privacy.accessibility.help` | Lets Flotsam paste into the app you are using. | (46/150) |
| `settings.privacy.input.help` | Lets triggers notice the text you type. Flotsam never stores keystrokes. | (72/150) |
| `settings.privacy.pasteOther.help` | macOS asks before apps read the clipboard. Choose Always Allow. | (63/150) |
| `settings.triggers.needInput` | Triggers need Input Monitoring. Open System Settings to allow it. | (65/150) |
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
| `onb.2.body` | macOS asks before apps read the clipboard. Choose Always Allow so Flotsam can save what you copy. | (97/150) |
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
| `ui.shelf.share` | Drop to share | (13/15) |

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
| `menu.pause` | Pause Capture (submenu: 15 Minutes, 1 Hour, Until Tomorrow, Until I Resume) | (13/15) |
| `menu.resume` | Resume Capture | (14/15) |
| `menu.notices` | Warnings and Errors | (menu item) |
| `menu.noNotices` | No Warnings or Errors | (menu item) |
| `menu.pausedUntil` | Paused until {time} | (disabled line) |
| `menu.pausedUntilResume` | Paused until you resume | (disabled line) |
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
