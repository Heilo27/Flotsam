# ADR-0003: Search strategy, default and spike dependency

Status: Accepted as a default; spike S-1 (TASK-004) may change it. Load-bearing: flagged to Friday.

## Context
FR-003-09: tokens split on whitespace, AND across tokens, each a case-insensitive, diacritic-insensitive substring of any searchable field. FR-003-10 and AC-007-16: p95 ≤ 100 ms per keystroke at 10,000 items (2,000 images). FR-007-18: `item.searchText` is a normalised concatenation of all searchable fields, rewritten in the same transaction as any change to a source field (tag rename rewrites every tagged item). Memory budget: 150 MB resident with 10,000 items (FR-001-20).

Measured today (not on macOS 14): the system `sqlite3` on the development machine is 3.54.0 and `CREATE VIRTUAL TABLE ... USING fts5(x, tokenize='trigram')` succeeds. SQLite introduced the trigram tokenizer in 3.34; macOS 14 ships an older library than this machine and its FTS5 availability is not verified here. Trigram cannot match tokens shorter than 3 characters.

## Decision
Default for v1 construction: **in-database substring scan**. Each token becomes `instr(item.searchText, :token) > 0` (the stored text is already normalised; the token is normalised by the same `SearchNormalizer` in Base), AND-ed, inside the active filter, executed on a reader connection, 200 rows per page plus count.
- It matches FR-003-09 by construction (substring, AND), including 1 and 2 character tokens.
- It holds no resident copy of the text: SQLite pages it through its cache, so the 150 MB budget does not depend on text size. (An "in-memory scan" of 10,000 items at up to 10,000 characters each could hold on the order of 100 MB by itself.)
- It needs no schema beyond FR-007-03 and no OS feature check.

The query layer is one function in Storage taking filter, tokens, sort, page. The strategy is internal to Storage, so callers (Library) cannot depend on it.

**Switch rule, decided before the spike so the spike cannot rationalise:** if S-1 measures the scan above 100 ms p95 on the target machine class at 10,000 items with 2,000 images, add an FTS5 trigram external-content index over `searchText` as migration 2 (`item_fts`, kept in sync by the same transaction that rewrites `searchText`) and use it for tokens of 3 or more characters, with `instr` for shorter tokens. If the FTS5 tokenizer is unavailable at runtime (probe at open: create-and-drop a temporary trigram table), fall back to the scan and log `STO-POL` only; never fail. Equivalence with the scan is a required test either way (50 random queries, per S-1's AC).

## Request to Friday for spike S-1
TASK-004 compares trigram against an in-memory scan. Add a third arm, the in-database `instr` scan, because it is this ADR's default and it avoids the memory cost the in-memory arm hides. No FRD change.

## Alternatives rejected
- **FTS5 trigram as default.** Faster at scale in principle, but costs a schema, an OS availability check, a sync obligation on every `searchText` rewrite, index size (trigram indexes run several times the text), special-case handling for short tokens, and equivalence testing. All of that is unjustified until the scan misses the p95.
- **In-memory array of `searchText`.** Fastest reads; unbounded memory and a second copy that must be invalidated on every rewrite (a Rule 9 drift hazard).
- **Relevance-ranked FTS (bm25, unicode61).** Word-prefix semantics are not substring semantics; FR-003-09 and the Library's no-ranking rule forbid it.

## Consequences
Search quality is fixed by FR-003-09, not the technique; spike S-1 can change only latency and migration count. The default may ship unchanged if the scan passes.

## Reversibility
High. The strategy is private to Storage; moving to trigram is one migration plus one function body.
