# ADR-0013: Local MCP server over an AF_UNIX socket

Status: Accepted (2026-11-19). Reverses the 2026-11-16 CUT of "Local MCP server" in `docs/CUT.md` (Ryan, 2026-11-19: opt-in, local only, per-client approval). Specified in [FRD-010](../frd/FRD-010-LocalMCP.md).

## Context
Ryan ruled that an AI app may read the clipboard history if the user opts in, only on this Mac, with each AI app approved separately. Flotsam must keep its promise that it makes no network call (A4) and must not become an access surface any local program can use unasked. An MCP client launches a stdio program, so a helper is needed; the helper must reach the running app.

## Decision
- **Transport:** an `AF_UNIX` stream socket `mcp.sock` in the 0700 data folder, file mode 0600. No TCP, UDP or IP, so the NETWORK rule in `bin/check-architecture.sh` still bans every network API and merely allows `AF_UNIX`.
- **Helper:** `flotsam-mcp`, a tool target embedded in `Flotsam.app/Contents/MacOS`, a pure byte relay (stdin to socket, socket to stdout). It links FlotsamBase only (the socket name and address) and has no logic to attack.
- **Module:** a new target `FlotsamMCP` (Base, Storage). It holds the approval gate, the line framer, the JSON-RPC handler and the client-identity value. The OS-facing pieces (peer identity, socket server) are adapters in `App/Platform/` (ADR-0001 rule 2). Import table and rule 4 of ADR-0001 amended accordingly.
- **Identity from the OS:** the approved client is the helper's parent process. `getpeereid` must equal the current user; `LOCAL_PEERPID` gives the helper; `proc_pidinfo` gives its parent (1 or less is refused); `anchor apple generic` makes the key `signed:<id>:<team|apple>`, anything else `path:<path>`. The wire's `clientInfo` is never consulted.
- **Gate before bytes:** nothing is read from a connection until `MCPGate.admit` approves. Approval is read live from the persisted `mcp.approvals` list, per request.
- **Bounded:** one serial queue, no timers or polling; at most 8 connections; 1 MiB frames; 16 queued requests; 5 s write timeout; 300 s in-memory deny cooldown; one prompt at a time.
- **Read-only, filtered:** tools `search_history` and `get_item`; secure items and items from ignored apps are filtered in the query (`ExposedItems`), not after.
- **Exposed in the UI:** off by default; an alert warns that AI apps often send what they read to their cloud before the switch turns on.

## Alternatives rejected
- **Loopback TCP/HTTP server.** Reachable by any local process and any browser page; breaks the "no network API" rule and the A4 audit.
- **Identify by `clientInfo` in `initialize`.** Self-reported; any program can claim any name.
- **XPC.** Needs a signed, entitled bundle relationship an MCP client cannot use; MCP clients speak stdio.
- **App group or file-based request drop.** Polling, no peer identity.

## Consequences
- A second executable in the bundle that release signing must cover (FRD-009 FR-009-08 amended).
- A new setting pair and one error code, `SET-OS-002`.
- Flotsam can no longer claim "no process can read my history without my knowledge": an approved AI app can.

### Known limits (accepted, recorded so nobody assumes more)
1. The approval is for the helper's parent process. An interpreter (node, python) or a wrapper shell is that parent for every script run under it, so approving one approves all of them.
2. A path-keyed (unsigned) client is spoofable by anyone who can replace the file at that path.
3. The deny cooldown is in memory only; quitting Flotsam clears it.
4. Any process of the same user can connect to the socket and will be prompted. The prompt is the control, not the socket.
5. Cloud exfiltration is outside Flotsam's control: an approved AI app may send what it reads anywhere. The enable warning exists for this.
6. The parent process id is read after the connection is made; a process that exits and has its id reused in that gap can be mistaken (TOCTOU). The gate reads the live approval per request but cannot re-verify identity.
7. The helper is recognised by path equality with the bundled helper; its own code signature is not verified beyond that.
8. One serial queue and 8 connections: a busy or hostile local client can slow or fill the server (it cannot read past the gate or exceed the limits). Denial of service to the user's other AI apps is possible, to Flotsam's capture is not.

## Reversibility
High. Remove the switch, the `FlotsamMCP` target and the helper; no stored data depends on them (`mcp.*` settings are inert).
