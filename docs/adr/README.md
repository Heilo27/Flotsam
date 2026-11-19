# Architecture Decision Records

One file per significant decision. Format: Status, Context (forces), Decision, Alternatives rejected, Consequences, Reversibility. An ADR is amended in place (with a dated line) when a spike lands; a reversal is a new ADR that supersedes the old one.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-module-structure.md) | One SPM package, ten targets in layers, platform adapters in the app target | Accepted |
| [0002](0002-sqlite-binding-grdb.md) | GRDB (system SQLite) is the only SQLite binding | Accepted |
| [0003](0003-search-strategy.md) | Search default: in-database substring scan; FTS5 trigram pending spike S-1 | Accepted (default), S-1 pending |
| [0004](0004-concurrency-model.md) | Concurrency model: actors, MainActor boundary, tap thread | Accepted |
| [0005](0005-paste-back.md) | One `PasteService` for Library, hotkeys and triggers; CGEvent ⌘V | Accepted |
| [0006](0006-global-hotkeys.md) | In-house Carbon `RegisterEventHotKey` wrapper; no KeyboardShortcuts package | Accepted, S-5 pending |
| [0007](0007-trigger-engine-boundary.md) | Trigger engine: thin CGEventTap adapter, pure matcher | Accepted, S-9 pending |
| [0008](0008-screenshot-watcher.md) | FSEvents with polling fallback; recognition rules in one module | Accepted, S-8 pending |
| [0009](0009-single-source-homes.md) | Named single homes for strings, errors, settings, limits, kinds | Accepted |
| [0010](0010-dependency-allowlist.md) | Dependency allowlist: GRDB only | Accepted |
| [0011](0011-testing-seams.md) | Testing seams: ports for clock, pasteboard, filesystem, settings store | Accepted |
| [0012](0012-project-tooling.md) | xcodegen `project.yml` is the project; the `.xcodeproj` is generated and not committed | Accepted |
| [0013](0013-local-mcp-server.md) | Local MCP server: AF_UNIX socket, OS-verified client identity, per-client approval, read-only tools | Accepted |
