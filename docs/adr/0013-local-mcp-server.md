# ADR-0013: Local MCP server over an AF_UNIX socket

Status: Accepted (2026-11-19). Reverses the 2026-11-16 CUT of "Local MCP server" in `docs/CUT.md` (Ryan, 2026-11-19: opt-in, local only, per-client approval). Specified in [FRD-010](../frd/FRD-010-LocalMCP.md).

## Context
Ryan ruled that an AI app may read the clipboard history if the user opts in, only on this Mac, with each AI app approved separately. Flotsam must keep its promise that it makes no network call (A4) and must not become an access surface any local program can use unasked. An MCP client launches a stdio program, so a helper is needed; the helper must reach the running app.

## Decision
- **Transport:** an `AF_UNIX` stream socket `mcp.sock` in the 0700 data folder, file mode 0600. No TCP, UDP or IP. The NETWORK rule in `bin/check-architecture.sh` bans every network API by name; an `AF_UNIX` socket names none of them, so that rule alone cannot tell a local socket from any other. The SOCKET and AFUNIX rules therefore confine `socket(`, `bind(`, `listen(`, `connect(` and `AF_UNIX` to `App/Platform/MCPSocketServer.swift` and `App/MCPHelper/main.swift` (`AF_UNIX` may also appear in `MCPWire`, which builds the address for both ends). That is defence in depth against a careless change, not proof: a name-based lint cannot see every way to open a socket. The socket file is created under `umask(0o177)`, so it is never readable by anyone else even for an instant before `chmod`.
- **Helper:** `flotsam-mcp`, a tool target embedded in `Flotsam.app/Contents/MacOS`, a pure byte relay (stdin to socket, socket to stdout). It links FlotsamBase only (the socket name and address) and has no logic to attack.
- **Module:** a new target `FlotsamMCP` (Base, Storage). It holds the approval gate, the line framer, the JSON-RPC handler and the client-identity value. The OS-facing pieces (peer identity, socket server) are adapters in `App/Platform/` (ADR-0001 rule 2). Import table and rule 4 of ADR-0001 amended accordingly.
- **Identity from the OS:** the approved client is the helper's parent process. `getpeereid` must equal the current user. The connecting process is named by its audit token (`LOCAL_PEERTOKEN`) and its code is looked up by that token (`kSecGuestAttributeAudit`), not by a bare pid: the token carries the pid version, which changes on every `exec`, so a process that connects and then execs another program no longer matches, and the connection is refused. The token's pid must also equal `LOCAL_PEERPID`, and the lookup and the executable path are checked again after everything else was read. The connecting process must be the bundled helper (path equality). A program whose file name is `flotsam-mcp` or whose signing identifier is the helper's, but whose path is not the bundled one, is refused with no prompt, and a helper is never recorded as an approval. The helper's parent comes from `proc_pidinfo` (1 or less is refused) and is looked up by pid, which is advisory (limit 6). `anchor apple generic` makes the key `signed:<id>:<team|apple>`, anything else `path:<path>`. The wire's `clientInfo` is never consulted. The prompt shows the verified signing identity or path first and the app's name (which a program chooses for itself) second.
- **Gate before bytes:** nothing is read from a connection until `MCPGate.admit` approves. Approval is read live from the persisted `mcp.approvals` list, per request.
- **Bounded:** one serial queue, no timers or polling; at most 8 connections; 1 MiB frames; 16 queued requests; 5 s write timeout; 300 s in-memory deny cooldown per client; a global lockout (after 3 refusals within 10 minutes every unknown client is refused with no prompt until the window passes), held by one gate for the life of the app so turning the switch off and on does not clear it; one prompt at a time.
- **Read-only, filtered:** tools `search_history` and `get_item`; secure items and items from ignored apps are filtered in the query, not after. `ExposedItems` is the one MCP read gate for secure rows and ciphertext rows, and it reads through the shared ignored-apps rule (`IgnoredAppsGate`, applied by `Selection`, FR-008-42) rather than holding a filter of its own. A search by an AI app matches only what the tool returns: the text, note, tags, source app and the first 50 member file names. It never matches the recognised image text (`ocrText`), a bundle's name, the kind label or the original file path, so a query cannot be used to probe text the tool does not show. Storage keeps this as a separate column, `searchTextExposed` (schema version 5), written by the same `SearchIndex.refresh` that writes `searchText`.
- **Exposed in the UI:** off by default; an alert warns that AI apps often send what they read to their cloud before the switch turns on.

## Alternatives rejected
- **Loopback TCP/HTTP server.** Reachable by any local process and any browser page; breaks the "no network API" rule and the A4 audit.
- **Identify by `clientInfo` in `initialize`.** Self-reported; any program can claim any name.
- **XPC.** Needs a signed, entitled bundle relationship an MCP client cannot use; MCP clients speak stdio.
- **App group or file-based request drop.** Polling, no peer identity.

## Consequences
- A second executable in the bundle that release signing must cover: `bin/release.sh` signs `flotsam-mcp` explicitly, inside-out, before the app (FRD-009 FR-009-02, FR-009-08, AC-009-15).
- A schema version 5 column, `item.searchTextExposed`, backfilled on upgrade by one pass over every item (FRD-007 FR-007-17); the cost is one read and one write per item, once.
- A new setting pair and one error code, `SET-OS-002`.
- Flotsam can no longer claim "no process can read my history without my knowledge": an approved AI app can.

### Known limits (accepted, recorded so nobody assumes more)
1. The approval is for the helper's parent process. An interpreter (node, python) or a wrapper shell is that parent for every script run under it, so approving one approves all of them.
2. A path-keyed (unsigned) client is spoofable by anyone who can replace the file at that path.
3. The deny cooldown and the global lockout are in memory only; quitting Flotsam clears them. Turning the switch off and on does not (one gate lives for the app's life). The lockout bounds a program that keeps connecting to nag the user into allowing it; it also means a legitimate new AI app is refused for up to 10 minutes after three refusals.
4. Any process of the same user can connect to the socket and will be prompted. The prompt is the control, not the socket.
5. Cloud exfiltration is outside Flotsam's control: an approved AI app may send what it reads anywhere. The enable warning exists for this.
6. The connecting helper is identified by audit token, so an `exec` after connecting is caught. The helper's parent is not: the kernel offers no audit token for a parent, so it is found by pid. A same-user program can swap the parent's executable (`exec`) after the helper started and before the lookup, and be taken for the approved app. Identity through the helper is therefore a consent prompt, not a boundary against code running as the same user, and cannot be one: that code can read the plaintext database file directly (limit 4, FRD-010 section 1). The gate reads the live approval per request but cannot re-verify identity.
7. The helper is recognised by path equality with the bundled helper; its own code signature is not verified beyond that. A copy of the helper elsewhere (recognised by its file name or its signing identifier) is refused, not offered to the user.
8. One serial queue and 8 connections: a busy or hostile local client can slow or fill the server (it cannot read past the gate or exceed the limits). Denial of service to the user's other AI apps is possible, to Flotsam's capture is not.
9. The approvals and the on/off switch are in `UserDefaults`, which any program running as the same user can edit (for example with `defaults write`). Such a program can approve itself or turn the server on without a prompt. This is no new exposure: it could read the database file directly. The approval list is consent bookkeeping, not an access control.

## Reversibility
High. Remove the switch, the `FlotsamMCP` target and the helper; no stored data depends on them (`mcp.*` settings are inert).
