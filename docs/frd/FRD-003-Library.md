# FRD-003 — Library Panel

**Status:** Draft · 2026-11-16 · Constitution: [TRUTHS.md](../TRUTHS.md) · PRD: [PRD.md](../PRD.md) (feature F3) · Errors: [FRD-000](FRD-000-ErrorSystem.md)
**Owns:** the Library panel (window behaviour, layout, rows and grid, preview), search semantics, **the keyboard map (single source for every key the panel handles)**, paste-back, the Accessibility-denied fallback.
**Does not own:** the open-Library global hotkey binding ([FRD-005](FRD-005-ShortcutsTriggers.md)); the filter and sort model and organise actions ([FRD-004](FRD-004-Organize.md)); item data and schema ([FRD-007](FRD-007-RetentionStorage.md)).

## Truth Test
- Serves: P1 — this is the 3-second path: hotkey, type or arrow, Return, and the clip is pasted into the app you were using, with no mouse.
- Supports: S1 — sidebar filters and search by what a clip was (kind, tag, source app, note).
- Violates: none (no network use, including no link-metadata or favicon fetches).
- Verdict: KEEP

## 1. Purpose
A fast floating panel that appears over whatever you are doing, finds a clip, and pastes it back into the app you came from.

## 2. User Stories
- As a keyboard user, I press the hotkey, type two letters, press Return, and the text is pasted where my cursor was.
- As a user, I press ⌘3 to paste the third-most-recent clip without searching.
- As a user, I preview a clip (text, image, file) before pasting it.
- As a user without Accessibility permission, I still get the clip onto my clipboard and am told to press ⌘V.

## 3. Functional Requirements

**Panel behaviour**
- **FR-003-01** Window. The Library is an `NSPanel` with the non-activating style: it becomes key (receives typing) without making Flotsam the active app, so the previously active app stays frontmost. Floating level; collection behaviour allows all Spaces and full-screen auxiliary, so it appears over full-screen apps. One instance, created at launch and kept hidden (not rebuilt) between uses.
- **FR-003-02** Show and hide. The open-Library hotkey toggles. Before showing, the panel records the target app (frontmost application bundle id and process id), calls `captureNow` (FR-001-02), then shows. It hides on Esc (FR-003-08), the hotkey again, click outside, active-Space change, or a different app becoming frontmost. Hiding without a paste restores nothing and writes nothing.
- **FR-003-03** Placement and size. Opens on the screen that contains the pointer, horizontally centred, its top edge one third of the way down the screen's visible frame. Default 760 x 480 pt, minimum 560 x 360, user-resizable; size is remembered (`library.panelSize`, FRD-008 registry).
- **FR-003-04** Open state. Every open starts with: empty search, sidebar filter All, the newest item selected, list scrolled to top, preview closed, and the search field first responder. The previous filter and query are not restored.
- **FR-003-05** Open performance. Hotkey press to panel visible with the search field focused: p95 ≤ 150 ms with 10,000 items (PRD). To meet it, the 50 newest rows are held in memory ready to render, further rows page in 50 at a time off the main thread, and nothing is rebuilt on open. Measured by the `library.open` signpost.

**Content and layout**
- **FR-003-06** Layout. Search field across the top; sidebar on the left (FR-003-12); results in the centre; optional preview pane on the right (FR-003-14); one-line footer hint bar along the bottom (FR-003-18).
- **FR-003-07** Views. List (default) and grid, toggled with ⌘G, remembered (`library.viewMode`). List row is 44 pt tall and contains, in order: kind icon or 32 pt thumbnail (images, screenshots, files, folders, bundles); primary line; secondary line; trailing badges. Primary line by kind: text and richText = first 2 lines, at most 140 characters; link = the URL; color = a swatch plus the colour string; phone and email = the value; image and screenshot = "Image" or "Screenshot" plus pixel size; file and folder = the name; bundle = "{n} items" plus the first two names. Secondary line = source app name, relative time (relative date formatter; "Yesterday" or a date after 7 days), up to 3 tag chips plus "+n". Trailing badges: pin, trigger or shortcut present, ⌘1 to ⌘9 index for the first nine visible rows. Grid cell is 120 pt square: thumbnail or text card, with the same badges. Missing-file items show a "Missing" badge (`ui.library.missing`, "Missing"). An item is missing when it is a file, folder or bundle item and none of its members exist, using the same test as FR-003-15 step 1: each member is resolved by its bookmark, falling back to its stored path; a member that is a symbolic link whose target is gone counts as not existing, the same as paste. An empty bundle reads as Missing. The state is read from the disk each time a page of rows is read and is never stored, so a file restored or moved back clears it on the next read; it is not pushed live while a page stays on screen. Every consumer of rows (list, grid, Shelf) uses the same state.
- **FR-003-08** Keyboard map (the only definition). The search field is always first responder; any printable key types into it. Rows marked [FRD-004] or [FRD-005] execute actions defined there.
  | Key | Action |
  |---|---|
  | Any printable key | type into search (filters live) |
  | ↑ / ↓ | move selection (list); ← → ↑ ↓ move in grid |
  | ⌘↑ / ⌘↓ | first / last item of the results; ⌘↓ pages in every remaining page, so it reaches the true last item |
  | ⇧↑ / ⇧↓ | extend selection (multi-select) |
  | Return | paste selected item into the target app and close |
  | ⌥Return | paste as plain text (drops rich and image-only representations) and close |
  | ⇧Return | copy to clipboard only, close |
  | ⌘C | copy the selected item to the clipboard only, close (the same action as ⇧Return); when the search field has selected text, ⌘C copies that text instead and the row is untouched |
  | ⌘1 ... ⌘9 | paste the Nth visible row (as numbered by badges) and close |
  | Space (search field empty) / ⌘Y | toggle preview |
  | Esc | first press that applies: clear search if non-empty; else close preview if open; else, with several rows selected, reduce the selection to one row (the cursor row); else close panel |
  | ⌥↑ / ⌥↓ | previous / next sidebar filter |
  | ⌘G | toggle list and grid |
  | ⌘R | reveal in Finder (file, folder, bundle member, screenshot) |
  | ⌘P | pin or unpin [FRD-004] |
  | ⌘T | edit tags [FRD-004] |
  | ⌘N | edit note [FRD-004] |
  | ⌘E | edit text item [FRD-004] |
  | ⌘⌫ | delete selected [FRD-004] |
  | ⌘S | cycle sort: Recent, Oldest, Most Used, A to Z [FRD-004] |
  | ⌘⇧U | ungroup the selected bundle [FRD-004] |
  | ⌘K | open the shortcut and trigger editor for the selected item; does nothing for a secure item, which can carry no shortcut or trigger [FRD-005 FR-005-09] |
  | ⌘, | open Settings |
  With two or more items selected, Return, ⌥Return, ⇧Return and ⌘C are disabled (footer hint says so); ⌘P, ⌘T, ⌘N and ⌘⌫ (FRD-004) apply to all selected. Keys are fixed in v1 (not user-remappable). A key not handled passes to the search field. ⌘A, ⌘V, ⌘X, ⌘Z and ⇧⌘Z are deliberately absent from the table: they are the standard text-editing keys, provided by the main menu (FRD-008 FR-008-19) and acting on the focused field, including the edit card's. ⌘C is in the table (it copies the selected row, the same as ⇧Return, through the same secure-item gate, FR-003-23) except while the search field has selected text, when it is the standard text copy; in the Organize overlays and the edit card, which own the keyboard, ⌘C is always the standard text copy.

**Search**
- **FR-003-09** Search semantics. The query is split on whitespace into tokens; an item matches when every token matches (AND). A token matches as a case-insensitive, diacritic-insensitive substring of any searchable field: plain text (first 10,000 characters), link URL, note, tag names, source app name, file and folder names of files and bundle members, kind label, and the screenshot original file name. Results keep the active sort order (FRD-004); there is no relevance ranking. Searching runs within the active sidebar filter.
- **FR-003-10** Search performance. Typing a character to updated results: p95 ≤ 100 ms with 10,000 items (`library.search` signpost). Queries are cancelled and replaced as typing continues, so only the latest result renders.
- **FR-003-11** Result count and empty states. The footer shows "{n} items" for the current filter and query. No items at all shows the empty state (catalogue keys `ui.library.emptyTitle`, `ui.library.emptyBody`); no matches shows `ui.library.noResultsTitle`, `ui.library.noResultsBody`. Neither shows an error.

**Sidebar**
- **FR-003-12** Sidebar sections, top to bottom: All, Pinned; Types (Text, Rich Text, Links, Colors, Phone Numbers, Emails, Images, Screenshots, Files, Folders, Bundles); Tags (colour dot and name, alphabetical); Apps (source apps with icons, ordered by item count, top 15). Each row shows an item count. Exactly one row is selected at a time; the selection is the single filter defined in FRD-004 FR-004-10. A row with count zero is shown dimmed except in Types, where empty types are hidden.

**Preview**
- **FR-003-14** Preview pane (right side, toggled by Space or ⌘Y, 280 pt wide, resizable with the panel). Content: text in full (up to 20,000 characters, then "Show more"); rich text rendered with its formatting (from its stored RTF; a rich text item with only HTML shows plain text, since importing HTML could fetch remote resources); link as the URL text only (no network fetch, no favicon, no metadata); colour as a large swatch with its hex and rgb values (for hex and `rgb()` notations; any other notation, and any malformed one (non-ASCII hex digits, an empty or non-numeric `rgb()` slot, a non-numeric alpha), shows its text and no swatch; out-of-range channels clamp to 0-255; colour notation, classification as a colour item as well as the swatch, takes ASCII digits only, so text with any other digits, such as Arabic-Indic or fullwidth, is plain text and not a colour; likewise a number too large to be a finite value, 309 or more digits, is plain text and not a colour), the hex and rgb values as the first rows of the metadata block after kind; image and screenshot scaled to fit; file, folder and bundle members as Quick Look previews with names (up to 20 members shown, then "and {n} more"). Below the content, a metadata block: kind, source app, copied date and time, first-copied date, copy count ("Times copied"), paste count, size on disk, pixel size for images, then one row per tag (colour dot and name) and its note, each only when it has any. Preview is read-only. Opening preview never changes the selection.
- **FR-003-13** Thumbnails. Rows and cells display thumbnails produced by the storage pipeline (FRD-007 FR-007-07). A row whose thumbnail is not yet ready shows the kind icon and swaps when ready; scrolling never blocks on thumbnail generation. The in-memory thumbnail cache is capped at 64 MB (least recently used) and is emptied when the last panel (Library or Shelf) closes, so an idle app holds none (S5; target state: `releaseMemory()` exists but is called from the panels by TASK-383, once they are built).

**Paste-back**
- **FR-003-15** Paste sequence. On Return, ⌥Return, ⇧Return or ⌘1 to ⌘9: (1) if the item references files, resolve bookmarks and drop members that no longer exist; none left → `LIB-DAT-001`, no paste, panel stays open; (2) write the item to the general pasteboard: every stored representation for text-bearing kinds (plain text only for ⌥Return); the stored image data for image and screenshot kinds (written through `NSImage` so the system supplies standard image types); every existing member as a file URL for file, folder and bundle kinds; (3) mark the write as Flotsam's own (FR-001-03); (4) increment the item's `pasteCount` and set `lastUsedAt` (FRD-007); (5) hide the panel; (6) for paste actions only: wait until the panel is no longer visible plus a settle delay of 40 ms, confirm the frontmost application is still the recorded target, then post ⌘V (key code 9 with the Command flag, key down then key up) addressed to the recorded target's process (`CGEvent.postToPid`), not to the session event tap (FR-003-16). ⇧Return performs steps 1 to 5 only, and is logged as `paste.copy`, not `paste.back` (FRD-000 FR-000-11).
- **FR-003-16** Target app mismatch or post failure. If the frontmost application is not the recorded target after 250 ms, or the event cannot be posted, the item stays on the pasteboard, nothing is pasted, and `LIB-OS-001` shows a HUD. A pasted item is never re-written after the event is posted. The ⌘V is addressed to the target's process, and the poster re-reads the frontmost application and the target's running state immediately before posting; if the target is no longer frontmost or no longer running, nothing is posted and the same failure applies. The session event tap is not used for ⌘V, because it delivers to whichever application has focus when the window server routes the event, so a focus change after the check would paste the clip into a different app (security finding F4, TASK-345). *Trade-off:* a process-addressed event bypasses the window server's focus routing, so it reaches the target's own event queue; this was chosen over the session tap because a misdirected paste leaks the clip, while a target that ignores a process-addressed ⌘V only fails to paste (the item is on the pasteboard and the user can press ⌘V). `postToPid` reports no delivery failure, so such a target shows no `LIB-OS-001`. Whether any target class (sandboxed, Electron, Terminal) ignores a process-addressed ⌘V is not yet confirmed; the dogfood matrix (Assumption 2) must include it, and if one does, the fix is a per-bundle fallback decided then, not a silent return to the session tap.
- **FR-003-17** Accessibility denied. When `AXIsProcessTrusted()` is false, paste actions perform steps 1 to 5 of FR-003-15 only (same as ⇧Return) and show the HUD `SET-PRM-001`; the HUD throttle (FR-000-08) may suppress repeats, so the footer hint bar also shows, while permission is missing, the persistent text `ui.library.footerCopyOnly` ("Press ⌘V to paste"), and the panel closes after Return as usual. Everything else in the Library works without Accessibility.
- **FR-003-19** Latency. Return to ⌘V posted: p95 ≤ 150 ms (`paste.back` signpost, which a copy-only paste does not emit because it posts no ⌘V), excluding the target app's own handling. Task falsifier (TRUTHS P1): hotkey to pasted, for a clip from yesterday located by typing, has a median ≤ 3 s in the timed dogfood task.

**Hints, data errors, accessibility**
- **FR-003-18** Footer hint bar shows the three most relevant keys for the state (for example "Return Paste  ⌥Return Plain  Space Preview"), the active sort's name (FR-004-12) beside the item count, and the copy-only notice when applicable. While Accessibility is denied (FR-003-17) the second hint is "⌘C Copy" (the copy-only key, FR-003-08) in place of "⌥Return Plain"; with Accessibility granted it stays "⌥Return Plain". All text comes from the catalogue.
- **FR-003-20** Data errors. An item whose stored data is missing at paste time is deleted and shown as `LIB-IO-001`. A failed database read shows `STO-DB-004` inline in the results area with a Retry button; the panel keeps working.
- **FR-003-21** Accessibility. Every control is reachable and operable by keyboard; rows expose VoiceOver labels in the form "{kind}, {primary text up to 100 characters}, from {app}, {relative time}, pinned" with row actions available via the VoiceOver actions menu; the panel respects Reduce Motion (no slide, fade only), Increase Contrast, and light and dark appearance; hit targets are at least 44 pt tall; a visible focus ring marks the selection.
- **FR-003-22** Context menu (right-click, mouse path only). Entries in order: Paste, Paste as Plain Text, Copy, Preview, separator, Pin or Unpin, Tags..., Note..., Edit... (text only), Shortcut and Trigger..., Ungroup (bundle), separator, Reveal in Finder (where applicable), separator, Delete. Each performs the same action as its key in FR-003-08. A secure item's menu has neither Edit... nor Shortcut and Trigger... (FR-003-23, FR-005-09); the row and ⌘K follow one rule, so the row is offered exactly when ⌘K would open the editor for that item.
- **FR-003-23** Secure items: authorise, then re-copy. A secure item (FRD-001 FR-001-25) is shown as the fixed mask, never its text, with a lock; when its Keychain key cannot be read on this Mac the row also shows an "Unavailable" badge (the same catalogue string in the Library and the Shelf). Every action that would put its text on the pasteboard (Return, ⌥Return, ⇧Return, double-click, ⌘C, Paste, Paste as Plain Text and Copy in the context menu, and the Shelf's FR-006-21) first checks that the key is readable (`LIB-DAT-002` if not, and no prompt is shown, since nothing could succeed) and then asks the device owner to authenticate (Touch ID, Apple Watch or the account password), every time and with no grace period. A cancelled or failed check is `LIB-OS-002` and nothing is written, recorded or pasted. On success the text is decrypted only then and written as plain text alone (the mode does not matter) with `org.nspasteboard.ConcealedType` plus the own-write markers (FRD-001 FR-001-03), so other apps and clipboard managers treat it as the password it is, Flotsam does not capture its own re-copy, and the clipboard-variable `{clipboard}` (FRD-005 FR-005-17) reads it as empty. Accepted trade-off: because the item is re-copied to the general pasteboard, a password manager's own auto-clear of the clipboard no longer limits how long the password is exposed there.

## 4. Data Requirements
- Reads items, tags, source apps and counts through the storage query layer (FRD-007); writes only `pasteCount` and `lastUsedAt`.
- Settings read (FRD-008 registry): `library.viewMode`, `library.panelSize`.
- In memory: target app (bundle id, pid), selected item ids, current query, cache of 50 newest rows, thumbnail LRU (64 MB); the row cache and the thumbnail LRU are released when the panel closes (S5; target state, wired by TASK-383).

## 5. Business Rules
- Paste-back never modifies stored items (no re-save of what was pasted).
- Paste count increments on every successful pasteboard placement from the Library, including ⇧Return and the Accessibility-denied fallback.
- The panel never makes a network request.
- Search never matches on image pixels (A3: no OCR).
- Dragging out of Library rows is out of scope; the Shelf is the drag path (FRD-006).

## 6. Error States (codes in FRD-000 §7)
| Situation | Code | Behaviour |
|---|---|---|
| Target app changed or ⌘V could not be posted | LIB-OS-001 | item left on pasteboard; HUD |
| Stored data missing | LIB-IO-001 | item deleted; HUD |
| Referenced files all missing | LIB-DAT-001 | no paste; HUD; row marked Missing |
| Secure item copy not authorised | LIB-OS-002 | nothing written to the pasteboard; HUD (FRD-001 FR-001-25) |
| Secure item key missing or bytes unreadable | LIB-DAT-002 | no copy; HUD; row marked Unavailable |
| Accessibility not granted | SET-PRM-001 | copy-only; HUD and footer hint |
| Database read failed | STO-DB-004 | inline message with Retry |

## 7. Acceptance Criteria
- **AC-003-01** (FR-003-01,02) Given a text field in another app has focus, when the hotkey is pressed, then the panel appears over it, the other app stays active (its menu bar remains), typing goes to the search field, and pressing the hotkey again or Esc closes it with no change to the other app's text.
- **AC-003-02** (FR-003-01) Given a full-screen app on a second display with the pointer there, then the panel opens on that display over the full-screen app.
- **AC-003-03** (FR-003-04) Given a previous session left a query, filter and preview open, then the next open shows empty search, filter All, newest item selected, preview closed.
- **AC-003-04** (FR-003-05) Given 10,000 items and a scripted hotkey press, then p95 time to visible and focused over 50 runs is ≤ 150 ms.
- **AC-003-05** (FR-003-07) Given a seeded library with one item of each kind, then each row's primary line follows FR-003-07 and the first nine rows show ⌘1 to ⌘9 badges.
- **AC-003-05a** (FR-003-07) Given a file item, a folder item and a bundle item, when their files are deleted (for the bundle, all of its members), then the next read of rows marks each one Missing and the row shows the "Missing" badge; items whose files exist, a bundle with one member left, and every non-file kind are not marked; an empty bundle reads as Missing; restoring the file clears the mark on the next read.
- **AC-003-06** (FR-003-08) Given the panel is open, then each key in the table performs its action; with a non-empty query, Space types a space and does not toggle preview; ⌘Y toggles preview regardless.
- **AC-003-07** (FR-003-08) Given the query is "x" and Esc is pressed three times with preview open, then the first clears the query, the second closes preview, the third closes the panel. With three rows selected and an empty query and no preview, the first Esc leaves only the cursor row selected and the second closes the panel.
- **AC-003-08** (FR-003-09) Given items "Résumé draft", note "for Anna", tagged "work", from Safari, then queries `resume`, `anna`, `work`, `safari draft` each match it, and `resume zzz` does not.
- **AC-003-09** (FR-003-10) Given 10,000 items, then p95 latency from keystroke to results is ≤ 100 ms over 100 queries.
- **AC-003-10** (FR-003-15) Given Accessibility is granted and a text field is focused in Notes, Terminal, Safari, Xcode and VS Code, when Return is pressed on a text item, then the text is pasted in each; ⌥Return on a rich item pastes plain text in Notes.
- **AC-003-11** (FR-003-15) Given an image item and a bundle of 3 files, then Return pastes the image into Preview/Notes and the 3 files into a Finder window; if one bundle member was deleted, 2 are pasted; if all were deleted, nothing is pasted and `LIB-DAT-001` is shown.
- **AC-003-12** (FR-003-15,19) Given a paste, then `pasteCount` is incremented once, no new history item appears (own-write skipped), and p95 Return to ⌘V post is ≤ 150 ms.
- **AC-003-13** (FR-003-16) Given the user switches apps during the 250 ms window, then nothing is pasted, the item is on the pasteboard and `LIB-OS-001` shows.
- **AC-003-14** (FR-003-17) Given Accessibility is revoked, when Return is pressed, then the item is on the pasteboard, the HUD `SET-PRM-001` shows, the footer shows the copy-only notice on the next open, and the panel closes.
- **AC-003-15** (FR-003-14) Given a link item, then preview shows only the URL and no network request is made during the session (verified by a network monitor).
- **AC-003-16** (FR-003-12) Given tags "work" (3 items) and "home" (0 items) and no Emails in the library, then Tags shows both with counts, "home" dimmed, and Types has no Emails row.
- **AC-003-17** (FR-003-21) Given VoiceOver on, then a row reads as specified, all actions are reachable by keyboard only, and Reduce Motion removes slide animation.
- **AC-003-18** (FR-003-08) Given two items selected with ⇧↓, then Return is disabled and ⌘P pins both.
- **AC-003-19** (FR-003-23) Given a secure item and a cancelled Touch ID prompt, when Return, ⇧Return or ⌘C is used, then `LIB-OS-002` shows, nothing is written to the pasteboard and nothing is pasted; given the key is gone, then `LIB-DAT-002` shows with no prompt; given the prompt succeeds, then the pasteboard holds the plain text with `ConcealedType` and the own-write markers, Flotsam does not capture it again, and a following expansion's `{clipboard}` is empty; given a second paste, then the prompt appears again; the row and its Shelf card show only the mask, with an "Unavailable" badge when the key is gone.

## 8. UI Inventory
| Element | Type | Where | Behavior |
|---|---|---|---|
| Library panel | NSPanel | over current app | FR-003-01 to FR-003-05 |
| Search field | text field | panel top | always focused; live filter; clear button when non-empty |
| Sidebar rows | selectable list | panel left | All, Pinned, Types, Tags, Apps with counts (FR-003-12) |
| Result list rows | list | panel centre | FR-003-07; select, multi-select |
| Result grid cells | grid | panel centre | FR-003-07 |
| View toggle | segmented control | panel top right | list or grid (⌘G) |
| ⌘1 to ⌘9 badges | label | first nine rows | show quick-paste index |
| Kind icon / thumbnail | image | row leading | FR-003-07, FR-003-13 |
| Pin, trigger, Missing badges | icons/label | row trailing | state indicators |
| Tag chips | chip | row secondary line | up to 3 plus "+n" |
| Preview pane | pane | panel right | FR-003-14; Show more link |
| Footer hint bar | label row | panel bottom | key hints, count, copy-only notice |
| Empty and no-results states | illustration-free text | results area | catalogue strings |
| Inline error with Retry | message and button | results area | STO-DB-004 |
| Context menu | menu | right-click | FR-003-22 |
| Settings shortcut | key ⌘, | panel | opens Settings (FRD-008) |
| HUD | transient label | screen top-centre | FRD-000 FR-000-08 |

## 9. Assumptions to verify (architecture spikes)
1. A non-activating `NSPanel` that is key accepts text input while leaving the previous app frontmost, on macOS 26, including over full-screen apps.
2. The 40 ms settle delay and 250 ms window are sufficient across Terminal, Electron and browser targets; tune from the dogfood matrix.
3. Search at 10,000 items meets 100 ms with SQLite full-text indexing; the index design is FRD-007's (spike confirms trigram or scan strategy).
4. The default open-Library hotkey (FRD-005) does not collide with common system or app shortcuts.

## 10. Out of Scope
Dragging out of Library rows (Shelf, FRD-006). Remappable in-panel keys. Relevance ranking, search operators and saved searches. Pasting several selected items at once. Link metadata, favicons or any network preview. OCR of images (A3). Sharing or AirDrop (NOT DOING).
