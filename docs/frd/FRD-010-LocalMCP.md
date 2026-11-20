# FRD-010 — Local AI Access (MCP)

**Status:** Draft · 2026-11-19 · Constitution: [TRUTHS.md](../TRUTHS.md) · Decision: [ADR-0013](../adr/0013-local-mcp-server.md) · Errors: [FRD-000](FRD-000-ErrorSystem.md) · Settings: [FRD-008](FRD-008-OnboardingSettings.md)
**Owns:** the opt-in local MCP server (switch, warning, socket, client identity, approval and revoke, protocol, exposure rules, limits), the bundled `flotsam-mcp` helper, the `mcp.enabled` and `mcp.approvals` settings.
**Does not own:** the Settings window and pane layout (FRD-008), what counts as a secure item (FRD-001 FR-001-25), the ignored-apps list (FRD-008 FR-008-11), search semantics (FRD-003), what an AI app does with what it reads.

## Truth Test
- Serves: P1 (recall): an AI app can find "that thing I copied last week" for the user. Reference-feature precedence ruling, Ryan 2026-11-19 (TRUTHS.md changelog; `docs/CUT.md` row reversed): opt-in, local only, per-client approval.
- Violates: none. Flotsam itself makes no network call: the transport is an `AF_UNIX` socket (A4 holds). Anti-truth A1 and A4 untouched (no account, no telemetry). The privacy promise is bounded honestly by FR-010-02: an approved AI app may send what it reads to its own cloud, which Flotsam cannot prevent, so the user is told before the switch turns on.
- Verdict: KEEP, as the opt-in the ruling describes. Off by default; secure items and ignored-app items are never exposed.

## 1. Purpose
Let a user who wants it give an AI app of their choice read access to their clipboard history, one app at a time, revocable at any moment, with an honest warning first and a consent prompt in front of every program that asks. The prompt is a consent control, not a wall against code running as the same user: such code can already read the database file, and the on/off switch and the approvals sit in the same user's `UserDefaults` (ADR-0013 limits 4, 6, 9).

## 2. User Stories
- As a user, I turn on Local AI Access knowing what it means, and turn it off again to shut everything.
- As a user, I am asked about each AI app the first time it connects, by name, and can refuse.
- As a user, I revoke an AI app in Settings and it loses access at once, even mid-conversation.
- As a user, my passwords and anything from apps I told Flotsam to ignore are never readable by an AI app.

## 3. Functional Requirements
- **FR-010-01** Switch. `mcp.enabled` (bool, default `false`, FRD-008 registry). While off nothing listens: no socket file exists. Turning it on starts the server; turning it off, or quitting, closes every connection and removes the socket file. If the server cannot start (a socket path that does not fit, another live Flotsam serving the socket, a bind or listen failure) the switch is set back to off and `SET-OS-002` is shown; a switch that is on while nothing listens is never left.
- **FR-010-02** Warning. Turning the switch on first shows an alert, title `ui.settings.mcpEnableTitle`, body `ui.settings.mcpEnableBody`, buttons `ui.settings.mcpTurnOn` and Cancel. Cancel is the default button; only Turn On enables. The body states that most AI apps send what they read to their own cloud service, that secure items and items from ignored apps are never shared, and that each AI app is approved separately and can be revoked. The text lives only in the String Catalogue.
- **FR-010-03** Gate. Every connection passes the approval gate before a single byte is read from it. An approved client is admitted with no prompt. An unapproved client is prompted (FR-010-04). Approval is also re-checked before each request, so a revoke ends the conversation at the next message, and revoking closes that client's open connections at once.
- **FR-010-04** Identity and prompt. The client is the process that launched the `flotsam-mcp` helper (the helper's parent), identified by the operating system and never by what the client says on the wire: the connecting process must run as the current user (`getpeereid`); it is named by its audit token (`LOCAL_PEERTOKEN`, whose pid must equal `LOCAL_PEERPID`) and its code is looked up by that token, so a process that changed program after connecting (its pid version no longer matches) is refused; the lookup is repeated after the other facts are read and must still agree. The connecting process must be the bundled helper: a program whose file name or signing identifier is the helper's but whose path is not the bundled one is refused with no prompt, and a helper is never stored as an approval. The helper's parent is read with `proc_pidinfo` and looked up by pid (advisory, ADR-0013 limit 6); a helper with no live parent (parent id 1 or less) is refused. A client signed with an Apple-issued certificate (`anchor apple generic`) is keyed `signed:<identifier>:<team>`; any other (unsigned, ad-hoc, self-signed) is keyed `path:<executable path>`. The prompt shows what identifies the client (the signing identifier and team, or the executable path) first, and the app's name second, labelled as the name it shows itself as; with Allow and Don't Allow; Don't Allow is the default button.
- **FR-010-05** Approvals. `mcp.approvals` (list of approved clients: key, display name, date approved; default empty) is the only record of consent. Allow adds the client; the Privacy pane lists every approved client with a Revoke button; Revoke removes it. An empty list approves nobody. The list is read live, never copied.
- **FR-010-06** Refusal cooldown. A client the user refused is refused without a new prompt for 300 seconds, remembered in memory only (quitting clears it; turning the switch off and on does not). Three refusals within 10 minutes, by any clients, lock out every unknown client for the rest of that window: they are refused with no prompt, and the window slides (a refusal older than 10 minutes no longer counts). Approved clients are unaffected. Only one prompt is ever open: a client that connects while one is showing is refused without being remembered, and may retry.
- **FR-010-07** Transport and protocol. An `AF_UNIX` stream socket `mcp.sock` in the data folder (folder 0700, file 0600); no IP, TCP or UDP. MCP over JSON-RPC 2.0, one message per line, relayed by the bundled helper (`flotsam-mcp`, stdin to socket, socket to stdout, no logic). `initialize`, `ping`, `tools/list` and `tools/call` are answered; anything else gets a JSON-RPC error. At most 8 connections are open at once; a ninth is refused. A message longer than 1 MiB closes the connection; a client that queues more than 16 unanswered requests is disconnected; a write that makes no progress for 5 seconds closes the connection.
- **FR-010-08** Exposure. A secure item (FRD-001 FR-001-25) and an item whose source app is on the ignored-apps list (FRD-008 FR-008-11) are never returned, by search or by id; asking for one by id answers exactly as for an id that does not exist. The ignored-app hide is the shared read-time rule (FRD-008 FR-008-42), applied to this reader through the same query selection as the Library and not defined again here; the list is read on every request, so a change applies to the next one. What this reader adds on top is the secure-item, ciphertext and image-text exclusions. A search matches only what the result shows: the item's text, note, tags, source app name and the file names it lists (at most 50 per item). It never matches the recognised text of an image (FRD-007 FR-007-23), a bundle's name, the kind label or an original file path; the Library's own search (FRD-003 FR-003-09) is unchanged. The `search_history` tool description says the same.
- **FR-010-09** Limits. `search_history` returns 20 items by default and at most 50, newest first, each with at most 300 characters of text; `get_item` returns at most 20,000 characters of text; a file item lists at most 50 file names (names only, never paths); a query is at most 500 characters.
- **FR-010-10** Tools. Exactly two, both read-only: `search_history` (query, optional kind, optional limit) and `get_item` (id). The server can create, change, delete, copy or paste nothing.
- **FR-010-11** Helper path. The Privacy pane shows the path of the bundled helper (selectable text) as the program to give an AI app. The helper is embedded in `Flotsam.app/Contents/MacOS/flotsam-mcp`; with Flotsam not running, or the switch off, it prints a hint and exits.

## 4. Data Requirements
- Persisted: `mcp.enabled`, `mcp.approvals` in `UserDefaults` via the settings registry. Nothing else: no log of what was read.
- Not persisted: the refusal cooldown and lockout, open connections.
- The socket file exists only while the server runs.

## 5. Business Rules
- Consent is per AI app and lives in one list; the wire's self-reported name never decides anything.
- Nothing about a connection is read before approval.
- The tools are read-only; widening them is a new requirement, a new warning review and a new FRD revision.

## 6. Error States (codes in FRD-000 §7)
- `SET-OS-002` (Error): the server could not start; the switch returns to off (FR-010-01).

## 7. Acceptance Criteria
- **AC-010-01** (FR-010-01) Given a fresh install, then `mcp.enabled` is false and no `mcp.sock` exists; given the switch is turned on and confirmed, the socket exists with mode 0600 in the data folder; given it is turned off, the socket is gone and open connections are closed.
- **AC-010-02** (FR-010-01) Given another live process is serving `mcp.sock`, when the switch is turned on, then Flotsam does not take over the socket, the switch returns to off and `SET-OS-002` shows; given a stale socket file with no process behind it, then it is replaced and the switch stays on.
- **AC-010-03** (FR-010-02) Given the switch is off, when it is turned on, then the alert shows the title, body and buttons of the catalogue keys with Cancel as the default; given Cancel or Escape, then the switch stays off and `mcp.enabled` is false; given Turn On, then it is on.
- **AC-010-04** (FR-010-03, FR-010-04) Given an unknown AI app connects, then the prompt names it, and until Allow is chosen no request it sends is read or answered; given Allow, then the next request is answered and a relaunch of Flotsam does not ask again.
- **AC-010-05** (FR-010-04) Given a client whose wire `clientInfo` claims to be an approved app but whose process is not, then it is prompted as the process it is; given a process owned by another user, then the connection is refused; given a copy of the helper at any path but the bundled one, then it is refused with no prompt and nothing is stored; given a process that connects and then execs another program, then it is refused.
- **AC-010-06** (FR-010-05, FR-010-03) Given an approved client with an open connection, when the user taps Revoke, then that connection closes at once, its next request is not answered, and a new connection prompts again.
- **AC-010-07** (FR-010-06) Given the user chose Don't Allow, then the same client connecting again within 300 seconds is refused with no prompt, and after Flotsam is quit and reopened it prompts again; given a prompt is open, then a second unknown client is refused with no second prompt; given three refusals within 10 minutes, then any unknown client is refused with no prompt until the window passes, also after the switch is turned off and on, and after Flotsam is quit and reopened it prompts again.
- **AC-010-08** (FR-010-07) Given `mcp.sock`, then it is an `AF_UNIX` socket and a scan of the app for IP, TCP and UDP APIs finds none; given 8 open connections, then a ninth is refused; given a 1 MiB plus one byte line, the connection closes; given a client that stops reading, its connection closes within about 5 seconds and the server keeps serving others.
- **AC-010-09** (FR-010-08) Given a secure item and an item copied from an ignored app, then neither appears in any `search_history` result, `get_item` for either answers like a missing id, and adding an app to the ignored list hides its items from the next request; given an image whose recognised text is "invoice", then a `search_history` for "invoice" does not return it and the same word typed in the Library does.
- **AC-010-10** (FR-010-09, FR-010-10) Given 100 matching items, then `search_history` returns 20 by default and at most 50 with `limit` 50 and rejects 51; `tools/list` returns exactly `search_history` and `get_item`; no tool changes any item.
- **AC-010-11** (FR-010-11) Given Settings > Privacy with the switch on, then the helper's path is shown and selectable and equals the file in the app bundle; run by an AI app with the switch off, the helper prints the hint and exits non-zero.

## 8. UI Inventory
| Element | Type | Pane | Behavior |
|---|---|---|---|
| Let AI apps read my clipboard history | switch | Privacy | FR-010-01, FR-010-02 |
| Enable warning | alert (Turn On, Cancel) | Privacy | FR-010-02 |
| Program to give your AI app | selectable path | Privacy | FR-010-11 |
| Approved AI apps | list, Revoke per row, empty-state text | Privacy | FR-010-05 |
| Allow this AI app | alert (Allow, Don't Allow) | none (modal on connect) | FR-010-04 |

## 9. Assumptions and open items (flagged for Friday)
- The warning wording is proposed, not yet approved by Ryan.
- The known limits of the identity model (interpreters, path-keyed clients, same-user processes, an `exec` swap of the helper's parent, `UserDefaults` tampering) are recorded in ADR-0013 and are accepted, not fixed here.

## 10. Out of Scope
Write or paste tools, remote access, other transports, per-tool approval, an audit log of reads, MCP resources or prompts, any network listener.

## 11. Change Log
- 2026-11-19: FRD created (TASK-553).
- 2026-11-19: security review of TASK-553: search is limited to what a result shows (FR-010-08, schema version 5); identity by audit token, helper copies refused, prompt leads with the verified identity (FR-010-04); global refusal lockout that survives the switch (FR-010-06); consent-control wording (section 1); limits 3, 6, 7, 9 in ADR-0013.
