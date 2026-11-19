# LinkHiv parity dossier (clean-room) and gap matrix

Task: TASK-532. Author: Dax. Date: 2026-11-19. Authority: `docs/TRUTHS.md` reference clause (amended 2e73758): Flotsam must match LinkHiv's form factor and reach functional parity or better, reverse-engineered by black-box observation only.

## 1. Method and clean-room statement

- Everything below is a neutral description of observed or publicly claimed behaviour. No vendor copy is quoted. No vendor image, frame or video is stored in this repo. Frames used for geometry were extracted to a temporary folder outside the repo and are not committed.
- The app was NOT downloaded, installed, signed up for or paid for. Every fact comes from the vendor's public website, its public tutorial videos and its public blog and comparison pages. Nothing here was observed on a running copy of the app.
- Evidence tiers:
  - V = shown in a public vendor tutorial video (screen recording). Strongest available, but still vendor-curated, and the recordings may be zoomed or cropped.
  - M = stated in vendor marketing, FAQ, blog, comparison or terms copy. Claim, not observation.
  - N = not documented in any source seen. "N" means unknown, not absent.
- No independent source exists. Searches for Reddit, Product Hunt, X, YouTube, App Store and Setapp coverage found nothing about this product. Treat every row as vendor-reported.
- Geometry is approximate. It was read from pixel proportions in 1440x810 recordings whose zoom and display scale are unknown. Proportions are more trustworthy than point sizes.
- Dates: the vendor's V2 release post is 2026-07-09, privacy policy effective 2026-09-21, terms effective 2026-06-25. Pages were read on 2026-11-19. The vendor ships often; any row may be stale.

## 2. Sources

Public site (client-rendered SPA; body copy lives in the script bundle, captured locally in `.claude/scratch/linkhiv-copy.txt`, not committed):
- Tutorials (video, duration): sidebar 28 s, search 13 s, filter-sort 16 s, grid-and-rows 15 s, click-to-paste 20 s, preview-a-clip 19 s, copy-and-pin 11 s, add-a-tag 15 s, edit-a-clip 23 s, clipboard-island 56 s, island-share 29 s, text-expander 18 s, settings-tour 42 s. Under `/tutorials/<slug>` on the vendor domain.
- Feature pages: clipboard-island, clipboard-history-for-mac, text-expander-for-mac, screenshot-history-for-mac, beautiful-mac-clipboard-app-ux.
- Compare pages: versus Paste, Maccy, Spotlight, Raycast, Typinator, CopyPaste Pro.
- Blog: V2 release 2026-07-09; whats-new 2026-06-17; setup-after-purchase 2026-06-27; curated capture 2026-06-24; bundles 2026-06-21; privacy 2026-04-03; item types 2026-06-23; screenshots 2026-06-22; rich text 2026-06-26.
- Download, privacy, terms, FAQ pages.
- Citation keys used below: `ISL@t` Island tutorial at t seconds (sampled every 4 s, so +/- 4 s); `SET@t` settings-tour at t seconds (same tolerance); `GRID` grid-and-rows tutorial; `COPY` bundle string set; `FAQ`, `PRIV`, `TERMS`, `V2`, `CMP`.

## 3. Trial and access (reported only)

- Pricing as stated: a weekly plan covering one Mac, and a one-time lifetime plan ("Pro", stated as US$79) covering up to five personal Macs. Some copy also mentions a yearly plan. Other copy says one-time purchases with no recurring billing. The vendor's own copy is internally inconsistent on this (weekly/yearly versus "no subscription"). A 30-day money-back guarantee is stated for lifetime.
- Free trial: not documented for this product. The phrase "free trial" appears only in copy about a different product on a roundup page. One string says "Activate later if you like", which hints the app may run before activation, but no trial length, limits or conditions are stated. Status: UNKNOWN.
- What activation needs: a purchase email (the app activates against it), then a device count check. The Account pane (SET@36 s) shows status, activated email, plan, access type, device count, last-checked time, Refresh and Deactivate. The privacy policy says activation device identifiers are sent to the vendor. No account or password is required to use the clipboard features; the vendor states no cloud sync and no clipboard upload.
- A Standard plan limit is stated: history retention longer than three months requires Pro.
- We did not sign up, enter an email or pay. Doing so would need Ryan's explicit go-ahead (Rule 4a/4b).

## 4. Form factor, per surface

### 4.1 Library (main window)

- Kind: floating panel, no visible title bar in the compact layout, opened by a global shortcut (default shown in the menu as shift-command-V). Pastes back into the app you came from, which needs Accessibility (M, FAQ). [V ISL@0 menu; M]
- Size and proportion (approx.): in the sidebar recording the panel is about one third of screen width and close to square (about 1:1). Ours is 760x480 (1.58:1), three columns. Exact point size unknown. [V GRID, ISL@56]
- Regions: left sidebar of colour-coded type rows (All, Screenshots, Text, Links, Colors, Email, Phone, Images, Videos, Snippets, Folders, Files, Groups, then Shortcuts, Notes, Pinned lower down); a top strip with a sidebar-toggle button and coloured tag tabs (two sample tags plus an add button) and a layers/sort-like icon at the far right; a single results column; a thin footer with the app label on the left and five small icon buttons (settings, layout, search, add, close) on the right. No third preview column. [V GRID, ISL@56]
- List mode: one-line rows, each with a drag/pin handle at left, the text or a small image thumbnail, a small source-app icon, and a copy button at right. Hover reveals row actions. [V GRID; M "hover to reveal delete"]
- Grid mode: roughly 3 columns of rectangular dark cards, each showing the text or image preview, a source-app icon, relative time ("5 hr ago") and a small coloured kind badge at the corner. Link cards have a green badge. [V GRID]
- Settings choose between a sidebar layout and a "top bar" layout where types become a compact row of icons above the clips, plus three preview-and-size presets and a panel background of Default, Light or Dark. [V SET@0-4]
- Preview: opens on hover (a preview panel, from which a shortcut can be assigned), not a fixed column. [M V2; V preview-a-clip tutorial, not frame-sampled]
- Keyboard model: a recall shortcut, arrow navigation and paste with one key are claimed; the full key map is N. [M]
- States seen: empty-tag state ("No tagged clips", with hint to tag or open Library) [V ISL@32-36]; searching state with a spinner ("Searching...") [V ISL@40]; selected-filter chip with "Clear selection" [V ISL@16-28].
- Motion: "animate icons on hover" setting; durations N.

### 4.2 Island (companion panel)

- Placement: a dark, near-black panel hung from the top edge of the screen with rounded bottom corners, expanding out of the menu bar / notch area. In the recording the right part is cropped, so horizontal anchoring (centre vs left) is NOT established. [V ISL@4-12]
- Collapsed state: a small black tab at the top edge, about a quarter of the recording width and about 40 px tall, with a tiny document icon at its left. A setting adds a small branded "shoulder" beside the physical notch. [V ISL@52; V SET@8]
- Open and close: opens from the menu-bar menu item "Clipboard Island" [V ISL@0], by hovering the collapsed pill after a delay (setting "Open after hover", default 0.4 s, "Balanced") [V SET@8], and presumably by shortcut (N). Closes by moving away (N exact rule).
- Layout, top to bottom: toolbar row with three round buttons at left (grid, check/select, search) and three at right (pin filter, add, expand-to-Library); a row of coloured pill filters (All, Screenshots, Text, Links, Colors, Email, Phone, Images, Videos, Snippets, Folders) preceded by the user's tag chips; then one horizontal row of cards (text, link, image), each about 4:3, about 15% of recording width. Cards carry text or thumbnail, relative time and a kind badge. [V ISL@4-48]
- Search: tapping the search button swaps the toolbar for a text field; results replace the card row. [V ISL@36-44]
- Interactions: horizontal scroll (with an option to scroll the row with a vertical mouse wheel) [V SET@8]; click a pill to filter, with a status chip "X selected / Clear selection" [V ISL@16-28]; a pinned filter [V ISL@48]; drag cards out to other apps and drop files in [M FAQ]; a share drop area for AirDrop and system sharing [M, island-share tutorial].
- Focus: it is "without leaving your current app" (M). Non-activating is implied, not shown.
- Multi-display: setting to show it on the display under the pointer, default "Follow Focus" [V SET@8]. Resume position: reopens at the same clip for about 10 s, then returns to newest [V SET@8].
- Optional capture confirmation: a setting briefly shows the copied type when a clip is added [V SET@8].

### 4.3 Menu-bar menu (V ISL@0)

Entries in order: Open Library (with shift-command-V), Clipboard Island, Add (shift-command-A), Paste Queue (submenu), Pause Clipboard Capture (submenu), Clear Recent History (submenu), Clear History, Text Expander, Configured Triggers (submenu), Settings, Check for Updates, Quit. The status item is a small icon among other menu-bar items.

### 4.4 Settings (V SET@0-40)

- A separate window with traffic-light buttons, a sidebar-toggle in the title area, and a left source-list of panes in groups. Window proportion is landscape; the recording is zoomed so point size is N.
- Groups and panes: Clipboard (General, Clipboard Island, History, Privacy); Workflow (Shortcuts, Types, Tags); Power Tools (Power Search, Text Expander, AI & MCP marked beta, Paste Queue); Learn (Tips & Tricks); Account (Account, About).
- General: start at login; Library layout (sidebar or top bar); preview-and-size presets; panel background; filter-and-sort display toggles (tags on clips, source app icons, custom names in grid); interaction toggles (close after paste, animate icons on hover).
- Clipboard Island: display choice; notch icon; capture confirmation; open-after-hover delay; reopen position; wheel scrolling.
- Privacy: always-protected note for concealed/transient/auto-generated content; capture of cross-device (Universal) clipboard toggle; disable capture from known password managers; per-app rules with Add App (never capture, shorten lifetime, always keep).
- Types: toggle and reorder which types appear in Library and Island.
- Tags: create tags with colour swatches; a "tagged history" amount limit (stated as up to 500 text-like clips and 50 images).
- Text Expander: global on/off ("expand text while I type"), status row, trigger list with add.
- Paste Queue: pick several clips, then paste them one at a time with a dedicated shortcut (control-command-V shown), advancing after each successful paste.
- Account: activation (see section 3), Redo setup, Reset defaults.

### 4.5 Onboarding

Install by dragging the app into Applications from a disk image (M, string set), launch, macOS open confirmation, activate with purchase email, grant Accessibility and optional folder access, set shortcuts, screenshot pickup, privacy and retention (M, setup post). Window size, step count and layout are N. "Redo setup" exists in Account (V SET@36).

## 5. Function inventory (source in brackets)

1. Clipboard history of text, rich text (RTF/HTML kept within limits, with a toggle), links, colours (hex), phone, email, images, files, folders [M].
2. Automatic screenshot pickup from the screenshots folder, including a custom folder [M FAQ].
3. Auto-detected categories and colour-coded type filters, user can toggle and reorder types [V SET@16].
4. Search, then narrow by type, source app, tag [M FAQ; V ISL@36].
5. Pins, plus a pinned filter [V ISL@48].
6. Custom colour tags and per-clip notes [M V2; V SET@20].
7. Edit a clip, delete (hover action, context menu, bulk), clear recent or all history [M; V ISL@0].
8. Source-app labels and icons on clips [M V2; V GRID].
9. Bundles/groups: multi-file copies auto-bundle (toggle), manual bundle, rename, ungroup [M COPY].
10. Persistent per-item shortcuts that paste into the front app; assign from hover preview, right-click or Settings [M].
11. Text Expander: short triggers expand typed text; date, time and clipboard variables; rich-text literals keep links; not a full Typinator-class tool, by the vendor's own admission [M CMP].
12. Curated capture: only copies made with a chosen shortcut are saved; web images handled separately [M].
13. Pause capture, with timed submenu choices [V ISL@0].
14. Retention controls, keep forever, image history size and an efficient preset [M]. Standard plan caps at three months [M].
15. Privacy: local only, no account, no cloud; concealed/transient/auto-generated types protected; known password managers blockable; per-app rules [M PRIV; V SET@12].
16. Cross-device clipboard (Apple Universal Clipboard) captured by toggle [V SET@12; M FAQ].
17. Island: drag in and out, share drop zone for AirDrop/system sharing [M].
18. Paste Queue (sequential paste of several clips) [V SET@28].
19. Power Search: on-device text and QR-code recognition in images [M]. Optional Apple Intelligence titles, summaries and keywords [M]. Local MCP access for AI agents, beta [M, V SET@24 pane name].
20. Check for updates; in-app activation and licence revalidation [V ISL@0, SET@36].
21. Add (manual clip creation) via menu shortcut and plus buttons [V ISL@0].
22. Hover row actions, hover preview, drag-to-reorder handle [V GRID].
23. Launch at login [V SET@0].
24. Requires macOS 14 or later [M]. Ours requires macOS 26 (FR-009-11).

## 6. Gap matrix

Marks: PARITY, GAP, BETTER, DIFFERENT-FORM, CUT. "Ours" cites FRD or DESIGN. Verdict column applies to GAP and DIFFERENT-FORM per the Truth Test; ESCALATE means Ryan must rule (anti-truth or primary-truth conflict, or a prior CUT).

### 6.1 Form factor

| ID | LinkHiv fact | Ours | Mark | Verdict / note |
|---|---|---|---|---|
| FF-01 | Library: floating panel, global shortcut, pastes back, needs Accessibility | FR-003-01, -02, -15 | PARITY | |
| FF-02 | Library compact, near-square, sidebar plus list only | DESIGN 760x480, 3 columns | DIFFERENT-FORM | KEEP: add a compact layout (no preview column) beside the current one; keeps recall path (P1) |
| FF-03 | Layout choice: sidebar types or top-bar types | One layout | GAP | KEEP, low (serves clause only) |
| FF-04 | Tag tabs above the clips | Tags in sidebar (FR-003-12) | DIFFERENT-FORM | KEEP ours; reconsider with FF-03 |
| FF-05 | Sidebar collapse button | Not specified | GAP | KEEP, low |
| FF-06 | Sidebar type list includes Videos, Snippets, Groups, plus Notes and Shortcuts filters | FR-004-10 filter model: all, pinned, kind, tag, app only | GAP | KEEP (S1 recall); needs FRD-004 filter change |
| FF-07 | One-line list rows with source icon, thumbnail, copy button | 44 pt two-line rows (FR-003-07, -21) | DIFFERENT-FORM | KEEP ours: 44 pt targets are an accessibility rule; offer compact density |
| FF-08 | Hover-revealed row actions | Context menu and keys only (FR-003-22) | GAP | KEEP, mouse path only |
| FF-09 | Grid of rectangular cards with source icon, time, kind badge | Grid 120 pt cells (FR-003-07) | PARITY | Cell content details differ; cosmetic |
| FF-10 | Hover opens preview, shortcut editable there | Space/Cmd-Y preview column (FR-003-14) | DIFFERENT-FORM | KEEP both; hover preview is additive |
| FF-11 | Three preview-and-size presets | One preview rule | GAP | KEEP, low |
| FF-12 | Panel background Default, Light, Dark | System appearance only (FR-003-21) | GAP | KEEP, low |
| FF-13 | Footer with settings, layout, search, add, close buttons | Footer hint bar of keys (FR-003-18) | DIFFERENT-FORM | KEEP ours (keyboard truth P1); add optional buttons later |
| FF-14 | Option to stay open after paste | Always hides (FR-003-15 step 5) | GAP | KEEP, low |
| FF-15 | Searching spinner and empty-tag state | Loading not designed (DESIGN states matrix) | GAP | KEEP, small (state polish) |
| FF-16 | Island hangs from top edge or notch, horizontal card row | Shelf on left, right, bottom or under menu icon (FR-006-05) | DIFFERENT-FORM | KEEP: add a top-centre placement; Shelf keeps its edges |
| FF-17 | Island opens by hover on collapsed pill (0.4 s) or menu item | Drag dwell 300 ms, optional edge hover 500 ms, hotkey (FR-006-03) | DIFFERENT-FORM | KEEP: top edge hover zone is a small addition |
| FF-18 | Always-visible collapsed pill / notch shoulder | Nothing visible when idle (FR-006-02) | GAP | ESCALATE: conflicts with S5 "invisible on the machine"; recommend opt-in, default off |
| FF-19 | Search, type pills, tag chips, pin filter and expand button inside the Island | Shelf has no search or filter (FRD-006 non-goal) | GAP | KEEP (S1, S3); reverses an FRD-006 non-goal, not a truth; needs FRD edit by Friday |
| FF-20 | Island card row about 4:3 cards with time and kind badge | Cards 64 pt or 112 pt, no timestamps (FR-006-07) | DIFFERENT-FORM | KEEP ours for density; add kind badge and time on bottom/top strip |
| FF-21 | Island on display under pointer or following focus | Hotkey uses pointer screen, else hides on display change (FR-006-20) | GAP | KEEP, low |
| FF-22 | Island resumes position for about 10 s on reopen | Always starts at top (FR-006-06) | GAP | KEEP, low |
| FF-23 | Optional capture confirmation | Cut 2026-11-17, no toast | GAP | ESCALATE: existing CUT row says serves no truth; clause now applies. Recommend opt-in, default off |
| FF-24 | Settings: grouped source-list window with 12+ panes | Toolbar panes, 560 pt wide, 6 panes (FR-008-03 to -09) | DIFFERENT-FORM | KEEP ours; sidebar nav for settings is cosmetic; revisit in hill-climb |
| FF-25 | Menu-bar menu with Open Library, Island, Add, Pause (timed), Clear Recent, Settings, Updates, Quit | DESIGN menu bar; no timed pause, no clear-recent in menu | DIFFERENT-FORM | KEEP: add timed pause and Clear Recent submenus |
| FF-26 | Onboarding: guided setup with redo option | FR-008-12, 8 steps, "Show Setup Guide" | PARITY | Step content of theirs is N |
| FF-27 | Reduce Motion, VoiceOver, contrast support | FR-003-21, FR-006-19 | BETTER | Vendor claims none seen |
| FF-28 | Light and dark appearance | FR-003-21 | PARITY | Recordings show dark only |

### 6.2 Function

| ID | LinkHiv function | Ours | Mark | Verdict / note |
|---|---|---|---|---|
| FN-01 | History of text, links, images, files, folders, colours, phone, email | FRD-001 | PARITY | |
| FN-02 | Rich text kept, with a toggle | FR-001-10 stores RTF/HTML; no toggle | PARITY | Toggle is a setting gap, low |
| FN-03 | Screenshot pickup incl. custom folder | FRD-002, FR-008-10 | PARITY | |
| FN-04 | Auto type categories | FR-001-08, -09 | PARITY | |
| FN-05 | Toggle and reorder type list | None | GAP | KEEP, low |
| FN-06 | Search plus filters by type, app, tag | FR-003-09, FR-004-10 | PARITY | |
| FN-07 | Sort options | FR-004-12 four sorts | BETTER | Theirs N |
| FN-08 | Pins | FR-004-01 | PARITY | |
| FN-09 | Tags with colours | FR-004-02 to -05 | PARITY | |
| FN-10 | Notes | FR-004-06 | PARITY | |
| FN-11 | Edit a clip | FR-004-07 | PARITY | |
| FN-12 | Delete and clear history | FR-004-09, FR-007-11 | PARITY | |
| FN-13 | Source-app label and icon | FR-001-13, FR-003-12 | PARITY | |
| FN-14 | Auto-bundle multi-file copies | FR-001-12 | PARITY | |
| FN-15 | Auto-bundle toggle, manual bundle, rename bundle | FRD-004 non-goals | GAP | KEEP (S2 groups survive); reverses FRD-004 non-goals |
| FN-16 | Ungroup | FR-004-11 | PARITY | |
| FN-17 | Per-item hotkeys | FR-005-05 | PARITY | |
| FN-18 | Typed triggers with date, time, clipboard variables | FR-005-08 to -17 | PARITY | |
| FN-19 | Rich-text expansions keep links | FR-005-18 | PARITY | |
| FN-20 | Text expander beyond literals (macros, fill-ins) | Cut (A2) | CUT | Anti-truth A2; vendor itself says it is not a full expander |
| FN-21 | Curated capture | FR-001-19, FR-005-06 | PARITY | |
| FN-22 | Pause capture with timed choices | Paused mode, no timers (FR-007-12) | GAP | KEEP, low |
| FN-23 | Retention presets, keep forever | FR-007-09 | PARITY | Ours not plan-gated |
| FN-24 | Image size limit, efficient preset | FR-007-08 | PARITY | |
| FN-25 | Local only, no account, no sync | A1, A4, FR-008-18 | PARITY | |
| FN-26 | Concealed and transient types protected | FR-001-04, -25 | BETTER | Ours stores concealed encrypted; theirs unknown (N) |
| FN-27 | Disable capture from known password managers | Ignored apps list (FR-008-11); no preset list | GAP | KEEP, low: preset list of password managers |
| FN-28 | Per-app rules: never capture, shorter lifetime, always keep | Ignore list only; per-app retention is a non-goal (FRD-007) | GAP | ESCALATE: reverses FRD-007 non-goal and risks S2 simplicity; recommend KEEP only "shorter lifetime" |
| FN-29 | Capture of Universal Clipboard toggle | FR-001-14 always captured as "Another device" | PARITY | |
| FN-30 | Tagged-history amount limit (tags keep clips longer) | Tag retention is a non-goal (FRD-004) | GAP | KEEP (S2); needs FRD-004/007 decision |
| FN-31 | Drag out of Island; drop into Island | FR-006-10, -12 | PARITY | |
| FN-32 | Drag out of Library rows | FRD-006 non-goal | GAP | KEEP (S3 drag first-class); N whether theirs does it |
| FN-33 | Island share zone (AirDrop, system sharing) | Shelf non-goal, v1.1 candidate | GAP | ESCALATE: Ryan to rule if clause overrides NOT DOING v1 |
| FN-34 | Paste Queue (sequential paste) | None | GAP | KEEP (S1/S4 flow); new FR needed |
| FN-35 | Add manual clip | None | GAP | KEEP, low (S4 trigger creation without copying) |
| FN-36 | Power Search: on-device OCR and QR | Cut (A3, no OCR) | GAP | ESCALATE: good feature, violates A3 |
| FN-37 | Apple Intelligence titles, summaries, keywords | CUT.md: serves no truth | GAP | ESCALATE: reference clause changes the test; privacy truth remains |
| FN-38 | Local MCP access | CUT.md: endangers Primary Truth | GAP | ESCALATE: recommend stay cut |
| FN-39 | Paid plans, activation, licence, device limits | Cut (A4) | CUT | Anti-truth A4 |
| FN-40 | Check for updates in the app | No updater, DEFER (FR-009-08, CUT.md) | CUT | Primary truth zero network (DEFER row), not an anti-truth; counted as CUT with that caveat |
| FN-41 | Launch at login | FR-008-15 | PARITY | |
| FN-42 | Tips and Tricks pane | None | GAP | KEEP, low |
| FN-43 | Reset defaults, redo setup | "Show Setup Guide"; no reset-defaults control | GAP | KEEP, low |
| FN-44 | Screen-recording pickup | Cut (A3) | CUT | N whether the vendor has it; listed because Videos type exists |
| FN-45 | Copy Diagnostics, tested resource budgets, atomic storage | FR-000-14, FR-007-13 | BETTER | |
| FN-46 | Open source, MIT, inspectable | LICENSE | BETTER | |

## 7. Counts

Counted from the tables above (FF 28 rows, FN 46 rows, total 74).

| Mark | FF | FN | Total |
|---|---|---|---|
| PARITY | 4 | 23 | 27 |
| GAP | 13 | 15 | 28 |
| BETTER | 1 | 4 | 5 |
| DIFFERENT-FORM | 10 | 0 | 10 |
| CUT | 0 | 4 | 4 |

(FF-18, FF-23, FN-28, FN-33, FN-36, FN-37, FN-38 are GAPs whose verdict is ESCALATE: 7 items.)

## 8. Proposed tickets (not created; Friday to file)

Priority P1 = serves a primary-truth path or the clause's most visible form factor; P2 = clear user value; P3 = polish.

| # | Title | AC (short) | FR ref | Pri |
|---|---|---|---|---|
| T1 | Island top-centre placement with horizontal card row | Shelf offers topCenter placement hung from menu bar; card row scrolls horizontally; opens by hover on top edge zone; passes FR-006-17 timings | FR-006-01, -03, -05 | P1 |
| T2 | Search and type/tag filter inside Shelf | Search field and type pills in Shelf (sticky mode, keyboard operable); results within 100 ms at 10k items; FRD-006 non-goal edited | FR-006 (new), FR-003-09 | P1 |
| T3 | Library compact layout | Layout with sidebar and list only, about square, switchable in Settings; keeps FR-003-05 open latency | FR-003-03, -06 | P2 |
| T4 | Paste Queue | Select several items, paste one per shortcut press, advance only after success; Esc cancels; copy-only without Accessibility | FR-003-15 (new FR) | P2 |
| T5 | Filters for Notes, Shortcuts, Videos, Groups | Sidebar rows added; counts update within 200 ms | FR-003-12, FR-004-10 | P2 |
| T6 | Hover row actions and hover preview | Hover reveals copy, pin, delete; preview opens after delay; keyboard model unchanged | FR-003-14, -22 | P2 |
| T7 | Manual bundling, bundle rename, auto-bundle toggle | Group selected items into a bundle; rename; setting for auto-bundle; one transaction | FR-004-11, FR-001-12 | P2 |
| T8 | Library drag-out | Dragging a row provides stored representations; secure items authenticate | FR-006-10 | P2 |
| T9 | Timed pause and Clear Recent in menu bar | Pause for 15 min, 1 h, until tomorrow; clear last 5 min, 1 h; mode icon reflects | FR-007-11, -12 | P3 |
| T10 | Password-manager preset in ignored apps | One-tap preset adds known password managers | FR-008-11 | P3 |
| T11 | Tag keeps clips longer (decision first) | Ryan decides; if yes, per-tag cap like pins | FR-004, FR-007-10 | P3 |
| T12 | Add manual clip | Menu item and shortcut create a text clip for triggers | FR-004-07 | P3 |
| T13 | Settings polish: panel background, preview presets, close-after-paste, reopen position, display follow, type reorder, reset defaults, tips | Each setting in registry with default | FR-008-01 | P3 |
| T14 | Loading and searching state in Library and Shelf | Spinner after 150 ms; empty-tag state | DESIGN states matrix | P3 |

ESCALATE list for Ryan (no tickets until ruled): FF-18 always-visible pill; FF-23 capture confirmation; FN-28 per-app lifetime rules; FN-33 share zone; FN-36 on-device OCR; FN-37 Apple Intelligence; FN-38 MCP.

## 9. Truth Test summary

- KEEP (serves S1, S2, S3, S4 or the reference clause): FF-02 to FF-08, FF-10 to FF-17, FF-19 to FF-22, FF-24, FF-25, FN-05, FN-15, FN-22, FN-27, FN-30, FN-32, FN-34, FN-35, FN-42, FN-43.
- ESCALATE: the seven listed above. None are decided here.
- CUT stays: FN-20 (A2), FN-39 (A4), FN-44 (A3), FN-40 (DEFER on zero-network).
- Pattern flag (Rule 8): the same-shape ESCALATEs are features the old truths cut as "serves no truth" that the reference clause now reaches (FF-23, FN-37, FN-38) and anti-truth A3 (FN-36). Ryan should say whether the reference clause overrides prior CUT rows or only adds scope that passes the other truths. Until then the old CUT rows stand.

## 10. Hill-climb (TASK-529) rubric deltas

- Add a rubric line "compact Library: one glance, sidebar plus list, no preview column" scored with the existing recall path.
- Add "Island/Shelf: top placement, horizontal row, collapsed state if enabled, search and filter states, empty and searching states".
- Add "Settings structure: grouped sidebar navigation versus toolbar panes" as a comparison, not a requirement.
- Add "hover affordances: row actions and preview".
- Do not score features that are ESCALATE until ruled.

## 11. Black-box access needed from Ryan

A copy of the app on a Mac Ryan controls, and written go-ahead, because I did not download, sign up or pay. Specifically:
1. A decision whether to start a trial or buy (Rule 4a/4b), and which email to use. Trial existence is UNKNOWN from public sources.
2. Screen recordings or screenshots taken by Ryan on that copy, kept outside the repo, for: exact Library and Island point sizes and corner radii, Island anchoring on a notched and a non-notched display, hotkeys and the full key map, onboarding steps and window size, Settings window size, motion durations, focus behaviour (does it steal focus or stay non-activating), paste-back timing, and what the trial or unactivated mode allows.
3. Ryan's permission to observe only behaviour, never decompile or read the app's code or assets (clean-room), and to keep captures out of the public repo.

## 12. Limits of this dossier

- Single vendor source; no independent verification.
- Tutorial recordings are curated and possibly zoomed; geometry is proportional only.
- Several panes and behaviours (Paste Queue details, Power Search, AI and MCP) are known only by pane name or one-line copy.
- The vendor's own copy contradicts itself on pricing; no claim is made about which is current.
