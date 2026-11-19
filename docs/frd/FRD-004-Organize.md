# FRD-004 — Organize

**Status:** Draft · 2026-11-16 · Constitution: [TRUTHS.md](../TRUTHS.md) · PRD: [PRD.md](../PRD.md) (feature F4) · Errors: [FRD-000](FRD-000-ErrorSystem.md)
**Owns:** pin, tags, notes, text editing, delete, ungroup, group into a bundle, bundle rename, **the filter model and the sort model**.
**Does not own:** where these controls appear and their keys ([FRD-003](FRD-003-Library.md) keyboard map); persistence and retention exemptions ([FRD-007](FRD-007-RetentionStorage.md)); triggers and shortcuts ([FRD-005](FRD-005-ShortcutsTriggers.md)).

## Truth Test
- Serves: S1 — tags, notes, kind and source-app filters and sorting let you find a clip you can only half-describe; ungroup serves S2 by letting a bundle be taken apart, and group and bundle rename serve S2 by letting files that were copied one at a time be kept together as one bundle under a name you recognise.
- Supports: P1 — pinning keeps the most-needed clips inside the 30-day window forever and one keystroke away.
- Violates: none. Group and rename reverse this FRD's earlier non-goals (recorded 2026-11-19 from the parity review, FN-14 and FN-15); they add no network, no new retention rule and no new store. Tags and notes are metadata on clips, not a snippet suite (A2); no sync of tags (A1).
- Verdict: KEEP

## 1. Purpose
Give users light-weight control over history: keep what matters, label it, annotate it, fix it, remove it, and slice the list the way they remember it.

## 2. User Stories
- As a user, I pin a clip I use every week so it never expires.
- As a user, I tag clips "client-a" and later filter to just those.
- As a user, I add a note ("staging DB password hint") so I can find a clip by what it was for.
- As a user, I fix a typo in a copied snippet without recopying it.
- As a user, I take a copied bundle of 12 files apart into single files.
- As a user, I sort by most used to find my go-to clips.

## 3. Functional Requirements

**Pin**
- **FR-004-01** Pin toggle. `pinned` is a boolean on an item, set and cleared with ⌘P, the context menu, or the Shelf. With a multi-selection: if any selected item is unpinned, all become pinned; otherwise all become unpinned. Pinned items are exempt from retention and budget eviction (FRD-007 FR-007-10), are listed under the Pinned filter, and show a pin badge. Pinning does not change an item's position in All (no floating).

**Tags**
- **FR-004-02** Tag rules. A tag has a unique id, a name and a colour. Name: trimmed, 1 to 32 characters, no control characters, unique case- and diacritic-insensitively; violation → `ORG-VAL-001`. Colour is one of the closed set `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `gray` (default `gray`; the actual colour values belong to the design system). At most 100 tags (`ORG-LIM-002`); at most 10 tags per item (`ORG-LIM-001`).
- **FR-004-03** Tag editor (⌘T, context menu). A popover anchored to the selection with: a field to filter or create ("Create tag 'name'" when no exact match), a list of all tags with check state, colour dot and count. Toggling applies immediately. With a multi-selection a tag shows a mixed state when only some selected items have it; toggling a mixed tag applies it to all. Return in the field toggles the first match or creates the tag and applies it. Esc closes the popover.
- **FR-004-04** Tag management. In the sidebar, a tag's context menu offers Rename (inline field, FR-004-02 rules), Colour (the eight values) and Delete. Deleting a tag removes it from all items without deleting items; if the tag is on at least one item a confirmation shows "Remove tag '{name}' from {n} items?" (`ui.organize.confirmDeleteTag`) with the count pluralised through the catalogue's plural variant ("1 item", "{n} items"; no hard-coded "items"). Whether to ask is decided by `LibraryOrganizer.deleteTagNeedsConfirmation(itemCount:)`, the one home for the rule. Renaming and recolouring change all items at once and never change item order.
- **FR-004-05** Tags are searchable and filterable (FRD-003 FR-003-09, FR-004-10). Tags have no effect on retention (a tagged, unpinned item expires normally).

**Notes**
- **FR-004-06** Note. One plain-text note per item, at most 2,000 characters (`ORG-VAL-002`), edited in a popover (⌘N, context menu); Return inserts a newline, ⌘Return saves, Esc cancels without saving. Only a zero-length note removes it; a note of spaces or newlines is stored exactly as typed. Notes are searchable (FRD-003 FR-003-09). Notes have no effect on retention.

**Edit text**
- **FR-004-07** Editable kinds: `text`, `richText`, `link`, `color`, `phone`, `email`. Other kinds → `ORG-VAL-003`. Editing opens an in-panel editor (⌘E, context menu) showing the plain text; ⌘Return saves, Esc cancels. The saved text must contain a non-whitespace character (`ORG-VAL-003`) and be at most the text ceiling (FRD-007 FR-007-06; `ORG-LIM-003`). On save: the plain text is replaced; stored rich representations (RTF, HTML) are removed (the editor shows the notice `ui.organize.editFormattingRemoved` for richText items); the kind is re-detected with FR-001-09; the `contentKey` is recomputed (FR-001-15); `updatedAt` is set. `createdAt`, `lastCopiedAt`, tags, note, pin and shortcuts are unchanged. A trigger or hotkey on the item uses the new text from then on.
- **FR-004-08** Duplicate keys after edit. An edit may make an item's `contentKey` equal to another item's; both are kept. For later captures, FR-001-15 bumps the matching item with the most recent `lastCopiedAt`.

**Delete and ungroup**
- **FR-004-09** Delete. ⌘⌫ or the context menu deletes the selected items immediately and permanently (rows, representations, stored blobs and thumbnails; FRD-007 FR-007-15). There is no undo and no trash. A confirmation (`ui.organize.confirmDelete`, or `ui.organize.confirmDeleteOne` for a single item) is shown only when more than one item is selected, or when any selected item is pinned or has a trigger or hotkey. Deleting a bundle, file or screenshot item never deletes any file on disk. Selection moves to the item after the last deleted one. A confirmed delete acts only if the selection is still the one the user confirmed; if it changed while the question was open, nothing is deleted.
- **FR-004-11** Ungroup. Available only when exactly one `bundle` is selected. It replaces the bundle with one item per member: kind `file` or `folder`, `createdAt` and `source` copied from the bundle, `lastCopiedAt` = the bundle's `lastCopiedAt` minus the member's zero-based index in milliseconds (so Recent shows members in their original order), tags copied from the bundle. The bundle's note, pin, trigger and hotkey are not carried over; if the bundle has any of them a confirmation (`ui.organize.confirmUngroup`) says so first. A confirmed ungroup acts only if that bundle is still the one selected; otherwise nothing changes. Each new item's `contentKey` is computed, with no dedupe against existing items. Ungroup is one transaction: all members are created and the bundle removed, or nothing changes.
- **FR-004-41** Group into a bundle (⌘⇧G, context menu "Group into Bundle"). Available when two or more items are selected and every one of them is a `file`, `folder` or `bundle`. All their members, in selection order (a selected bundle contributes its members in their own order), become one new `bundle`: kind and `contentKey` are what a copy of the same paths would get (FRD-001 FR-001-12, FR-001-15), so a later copy of those files bumps this bundle; `createdAt` and `lastCopiedAt` are now, so it sits at the top of Recent; `source` is carried only when every selected item has the same one; tags are the union of the items' tags, up to 10 (`ORG-LIM-001` is not raised: the extra tags are left off). The selected items' notes, pins, triggers and hotkeys are not carried over; if any selected item has one, a confirmation (`ui.organize.confirmGroup`) says so first. A confirmed group acts only if the selection is still the one asked about; otherwise nothing changes. The originals are removed through the same delete as FR-004-09 (their blobs and thumbnails go with them); files on disk are never touched. The new bundle becomes the selection. Fewer than two items, an item of another kind, or more than 500 members in all → `ORG-VAL-004`, shown as a HUD (there is no inline field), and nothing changes; unlike capture (FR-001-12) group never trims. No dedupe against existing items. Group is one transaction: the bundle is created and the originals removed, or nothing changes.
- **FR-004-42** Rename a bundle (⌘⇧R, context menu "Rename", available only when exactly one `bundle` is selected). An in-panel card edits the name; Return saves, Esc cancels. The name is trimmed, 1 to 100 characters, no control characters (`ORG-VAL-005`, inline). A blank name clears it. A named bundle's row shows the name as its primary line in place of its first member names (FRD-003 FR-003-07), the name is searchable (FRD-003 FR-003-09), and the member list and the files on disk are unchanged. Renaming does not change `lastCopiedAt` or any sort position. Rename is one transaction with the search text refresh (FR-007-18). A bundle's name is user text: it is excluded from logs (FR-000-10).

**Filter and sort**
- **FR-004-10** Filter model (single definition). `LibraryFilter` is exactly one of: `all`; `pinned`; `hasNote` (the item has a note, FR-004-06); `hasShortcut` (the item has a hotkey or a trigger, FRD-005); `videos` (a file or bundle item with at least one member whose extension is mov, mp4, m4v, avi, mkv, webm, mpg, mpeg, 3gp, wmv or flv, directories excluded); `kind(ItemKind)`; `tag(tagId)`; `sourceApp(identity)`; plus an independent free-text query (FRD-003 FR-003-09). `sourceApp` identity is the bundle identifier, or the buckets "Another device" and "Unknown". The sidebar (FRD-003 FR-003-12) is the only UI that sets the filter.
- **FR-004-12** Sort model (single definition). `library.sort` is one of: `recent` (default; `lastCopiedAt` descending), `oldest` (`lastCopiedAt` ascending), `mostUsed` (`pasteCount` descending, then `lastCopiedAt` descending), `alphabetical` (locale-aware, case-insensitive standard comparison of the primary line text defined in FRD-003 FR-003-07, then `lastCopiedAt` descending). Items with equal keys fall back to `lastCopiedAt` descending, then id, so order is stable. Pinned items are not floated in any sort. ⌘S cycles the sort in that order; the footer names the active sort (`ui.organize.sortRecent`, `ui.organize.sortOldest`, `ui.organize.sortMostUsed`, `ui.organize.sortAlphabetical`: Recent, Oldest, Most Used, A to Z); the choice is remembered.
- **FR-004-13** Counts. Sidebar counts (FRD-003) and the "{n} items" footer reflect the filter and update within 200 ms of any pin, tag, edit, delete, group, ungroup, rename or capture.

**Atomicity and speed**
- **FR-004-14** Every action in this FRD is one database transaction; on failure the whole action rolls back and shows `STO-DB-001`, leaving the UI as before. Single-item actions complete within 100 ms p95 with 10,000 items; actions on up to 500 selected items within 1 s.

## 4. Data Requirements
Fields owned by this FRD (schema in FRD-007): item `pinned`, `note`, `name` (bundles only; FR-004-42), `updatedAt`; tag `id`, `name`, `color`; item-tag link. Settings: `library.sort` (FRD-008 registry). Display text for confirmations from the catalogue.

## 5. Business Rules
- Only pin and trigger/hotkey exempt an item from retention; tags and notes do not.
- Tag names are labels, never content: they are excluded from logs (FR-000-10).
- Editing never changes when an item was copied.
- Delete never touches files outside Flotsam's data folder.
- "Most used" counts pastes from Flotsam (`pasteCount`), not repeated copies.

## 6. Error States (codes in FRD-000 §7)
| Situation | Code | Behaviour |
|---|---|---|
| Tag name empty, over 32, or duplicate | ORG-VAL-001 | inline, rejected |
| Note over 2,000 characters | ORG-VAL-002 | inline, rejected |
| Edit on a non-text kind, a secure item, or empty text | ORG-VAL-003 | rejected |
| More than 10 tags on an item | ORG-LIM-001 | assignment rejected |
| More than 100 tags | ORG-LIM-002 | creation rejected |
| Edited text over ceiling | ORG-LIM-003 | rejected inline |
| Group needs 2 or more file, folder or bundle items and at most 500 members in all | ORG-VAL-004 | HUD, rejected, nothing changes |
| Bundle name over 100 characters or with a control character | ORG-VAL-005 | inline, rejected |
| Transaction failed | STO-DB-001 | rolled back; surfaced per FRD-000 |

An input rejection shown inline (ORG-VAL-001 to -003, ORG-VAL-005, ORG-LIM-001 to -003) is still logged and recorded, and never raises a HUD (FRD-000 FR-000-08 d).

## 7. Acceptance Criteria
- **AC-004-01** (FR-004-01) Given items A (pinned) and B (unpinned) selected, when ⌘P is pressed, then both are pinned; pressing again unpins both; a pinned item older than the retention window survives a sweep.
- **AC-004-02** (FR-004-02) Given tags "Work" and "work", then the second is rejected with `ORG-VAL-001`; a 33-character name, an empty name and a name of spaces are rejected; "Résumé" and "resume" are treated as duplicates.
- **AC-004-03** (FR-004-02) Given an item with 10 tags, then an 11th is rejected with `ORG-LIM-001`; given 100 tags exist, creating a 101st is rejected with `ORG-LIM-002`.
- **AC-004-04** (FR-004-03) Given 3 items selected and a tag on only one of them, then the editor shows mixed state, toggling applies to all 3, toggling again removes from all 3.
- **AC-004-05** (FR-004-04) Given a tag on 5 items, when it is deleted and confirmed, then the 5 items remain without it; renaming it updates the sidebar and all rows with no reorder.
- **AC-004-06** (FR-004-06) Given a 2,001-character note, then it is rejected with `ORG-VAL-002`; a note saved with ⌘Return is findable by search; clearing it removes it.
- **AC-004-07** (FR-004-07) Given a richText item edited and saved, then RTF and HTML are gone, the kind is re-detected (editing to `https://x.y` makes it `link`), `lastCopiedAt` is unchanged, and tags and pin remain; given an image item, ⌘E is rejected with `ORG-VAL-003`; given whitespace-only text, rejected.
- **AC-004-08** (FR-004-08) Given an edit that makes item A's text equal item B's, then both exist; copying that text bumps the one with the later `lastCopiedAt`.
- **AC-004-09** (FR-004-09) Given one unpinned item, ⌘⌫ deletes at once with no dialog; given a pinned item or 3 selected items, a confirmation shows first; given a bundle, the files on disk remain; the record and its blobs are gone afterward.
- **AC-004-10** (FR-004-11) Given a bundle of 4 files with tag "x", a note and a pin, then Ungroup asks for confirmation, creates 4 items in the original order in Recent, each tagged "x", each without note or pin, and the bundle is gone; an injected failure on the 3rd insert leaves the bundle untouched.
- **AC-004-11** (FR-004-10) Given any sidebar row is selected, then exactly one filter applies; typing a query narrows within it; selecting All clears the filter but not the query.
- **AC-004-11b** (FR-004-10) Given an item with a note, an item with a hotkey, an item with a trigger, a bundle holding `clip.MOV` and a file `a.mp4`, then `hasNote` lists the first, `hasShortcut` lists the second and third, and `videos` lists the bundle and the file (extension match ignores case); each sidebar count equals the length of the list its row selects.
- **AC-004-12** (FR-004-12) Given 6 items with distinct text, pasteCounts and dates, then each sort yields the specified order, ties are stable across repeated loads, and ⌘S cycles Recent, Oldest, Most Used, A to Z, with the footer naming the active sort after every press.
- **AC-004-13** (FR-004-13,14) Given 10,000 items, then single-item pin, tag and delete each complete in ≤ 100 ms p95, and tagging 500 selected items in ≤ 1 s.
- **AC-004-41** (FR-004-41) Given a file, a folder and a 3-file bundle selected, with the file pinned and tagged "x" and the bundle tagged "y", then Group asks for confirmation, creates one bundle of 5 members in selection order (the bundle's own members in their order) at the top of Recent, tagged "x" and "y", with no pin, note, trigger or hotkey, selected; the three originals are gone and the files on disk remain; given one item, or a text item among the selection, or selections totalling 501 members, then it is rejected with `ORG-VAL-004` and nothing changes; an injected failure after the bundle insert leaves the 3 originals untouched and no bundle.
- **AC-004-42** (FR-004-42) Given one bundle, then Rename opens a card showing its current name (empty when unnamed); saving "Receipts" shows "Receipts" as the row's primary line and the query `receipts` finds it; a 101-character name is rejected inline with `ORG-VAL-005`; a blank name clears the name and the row shows its member names again; renaming a file, a folder or several items does nothing.
- **AC-004-14** (FR-004-05) Given a tagged but unpinned item older than the retention window, then it is removed by the sweep.

## 8. UI Inventory
| Element | Type | Where | Behavior |
|---|---|---|---|
| Pin badge and Pinned sidebar row | icon, row | Library | FR-004-01 |
| Tag popover | popover | anchored to selection (⌘T) | filter/create field, checklist with mixed states |
| Tag chips | chips | list row, preview metadata | name and colour |
| Sidebar tag rows with context menu | list rows, menu | Library sidebar | Rename, Colour (8), Delete |
| Delete-tag confirmation | alert | panel | FR-004-04 |
| Note popover | popover with multi-line field | anchored to selection (⌘N) | ⌘Return saves, Esc cancels, character counter near limit |
| Text editor | in-panel multi-line editor with Save/Cancel | replaces results area | ⌘Return saves, Esc cancels; formatting-removed notice for richText |
| Delete confirmation | alert | panel | FR-004-09 |
| Ungroup confirmation | alert | panel | FR-004-11 |
| Group confirmation | alert | panel | FR-004-41 |
| Bundle rename card | in-panel single-line field with Save/Cancel | replaces the results area | FR-004-42; Return saves, Esc cancels |
| Sort control | menu button and ⌘S | panel header | four options; checkmark on active |
| Inline validation text | label | by field | ORG-* messages |
| Context menu entries | menu | right-click | Pin/Unpin, Tags..., Note..., Edit..., Group into Bundle, Rename..., Ungroup, Delete (placement in FRD-003 FR-003-22) |

## 9. Out of Scope
Grouping items other than files, folders and bundles. Renaming anything but a bundle. Undo or trash. Nested tags, smart collections, tag sync (A1). Editing images or files (A3). Rich-text editing. Combining several filters at once. Tag-based retention rules.
