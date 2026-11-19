import Darwin
import FlotsamBase
import FlotsamMCP
import Foundation

/// The local MCP transport: an `AF_UNIX` stream socket in the data folder (ADR-0013). It is not a network listener: no
/// IP address, no port, no TCP, nothing reachable from another machine, and the socket file is 0600 inside the 0700
/// data folder, so only this user's processes can connect at all.
///
/// What it does, in order, for each connection:
/// 1. Accepts it, refusing outright past `maxConnections` open connections.
/// 2. Identifies the client from the operating system (`MCPPeerIdentity`), never from the wire.
/// 3. Asks `MCPGate` whether that client is approved, which may show the Allow prompt. **No byte is read from the
///    connection before the gate says yes**, so an unapproved client cannot even send a request.
/// 4. Only then reads, splits newline-delimited messages (bounded at `MCPWire.maxFrameBytes`) and answers them in order
///    through `MCPHandler`, re-checking approval before each one so a revoke stops the very next request.
///
/// No timer and no polling anywhere (ADR-0004 S5): everything is a dispatch source or a suspended task. All mutable state
/// lives on one serial queue (`queue`); the only other thread that touches a connection is its write queue, which owns
/// the descriptor's lifetime. Hence `@unchecked Sendable`: the queue discipline, not the compiler, is the guarantee.
final class MCPSocketServer: @unchecked Sendable {
    static let maxConnections = 8
    /// A client that stops reading cannot stall a response forever: a write that makes no progress for this long fails
    /// and the connection is closed.
    private static let writeTimeoutSeconds = 5
    /// Requests buffered per connection beyond the one in flight. A client that sends more than this without waiting for
    /// answers is flooding, not conversing, and is disconnected.
    private static let maxQueuedRequests = 16

    private let socketURL: URL
    private let gate: MCPGate
    private let handler: MCPHandler
    private let queue = DispatchQueue(label: "io.github.heilo27.Flotsam.mcp-server")

    // Queue-confined.
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var running = false

    init(socketURL: URL, gate: MCPGate, handler: MCPHandler) {
        self.socketURL = socketURL
        self.gate = gate
        self.handler = handler
    }

    // MARK: Lifecycle

    /// Binds the socket and starts accepting. Fails (SET-OS-002) when the path is too long for a socket address, another
    /// live Flotsam already owns the socket, or the socket cannot be created, bound or listened on; nothing is left
    /// bound after a failure.
    func start() -> FlotsamResult<Void> {
        queue.sync {
            guard !running else { return .success(()) }
            switch Self.makeListener(at: socketURL) {
            case .failure(let error): return .failure(error)
            case .success(let descriptor):
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptPending(on: descriptor) }
                let path = socketURL.path
                source.setCancelHandler {
                    close(descriptor)
                    unlink(path)
                }
                acceptSource = source
                running = true
                source.resume()
                return .success(())
            }
        }
    }

    /// Stops accepting, closes every connection and removes the socket file. Idempotent.
    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            acceptSource?.cancel()
            acceptSource = nil
            for connection in connections.values { beginClose(connection) }
        }
    }

    /// Closes every connection whose client is no longer approved. Called when the approvals list changes; each
    /// request is checked too, so this only makes a revoke immediate for an idle connection.
    func revokeUnapproved() {
        queue.async { [self] in
            for connection in connections.values {
                let gate = gate
                let queue = queue
                let server = self
                let key = connection.identity.key
                Task {
                    guard await !gate.isApproved(key: key) else { return }
                    queue.async { server.beginClose(connection) }
                }
            }
        }
    }

    // MARK: Listening

    private static func makeListener(at url: URL) -> FlotsamResult<Int32> {
        let path = url.path
        guard let address = MCPWire.unixAddress(path: path) else {
            return .failure(FlotsamError(.setOs002, "the socket path does not fit a Unix socket address"))
        }
        // A live server on the path means another Flotsam owns it: do not steal it. A refused connection means the file
        // is a leftover of a process that is gone.
        if isServed(address) { return .failure(FlotsamError(.setOs002, "another process is serving the socket")) }
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(FlotsamError(.setOs002, "socket() failed")) }
        // The file is created by bind() with the process umask, so for that instant it could be group- or world-readable
        // before the chmod below. umask is process-wide: 0o177 only ever makes other files created in this window
        // stricter, never looser, and the previous value is put back straight after.
        let previousMask = umask(0o177)
        let bound = MCPWire.withSockaddr(address) { bind(descriptor, $0, $1) }
        umask(previousMask)
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, Int32(maxConnections)) == 0, setNonBlocking(descriptor, true) else {
            close(descriptor)
            unlink(path)
            return .failure(FlotsamError(.setOs002, "the socket could not be bound or listened on"))
        }
        return .success(descriptor)
    }

    private static func isServed(_ address: sockaddr_un) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        return MCPWire.withSockaddr(address) { connect(probe, $0, $1) } == 0
    }

    private static func setNonBlocking(_ descriptor: Int32, _ nonBlocking: Bool) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(descriptor, F_SETFL, nonBlocking ? flags | O_NONBLOCK : flags & ~O_NONBLOCK) == 0
    }

    // MARK: Accepting

    private func acceptPending(on listener: Int32) {
        // The source is level-triggered: anything left over fires again.
        let descriptor = accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        guard connections.count < Self.maxConnections, Self.configure(descriptor), let identity = MCPPeerIdentity.identify(connection: descriptor)
        else {
            close(descriptor)
            return
        }
        let connection = Connection(descriptor: descriptor, identity: identity)
        connections[ObjectIdentifier(connection)] = connection
        // Nothing is read until the gate answers. The connection holds its descriptor open, unread, meanwhile.
        let gate = gate
        let queue = queue
        let server = self
        Task {
            let admission = await gate.admit(identity)
            queue.async { server.admitted(connection, admission) }
        }
    }

    /// A connection stays in blocking mode (the listener's non-blocking flag may be inherited, so it is cleared): writes
    /// run on their own queue and are bounded by SO_SNDTIMEO, and a read is only made after the dispatch source says
    /// data is waiting, so it cannot block the server queue. No SIGPIPE.
    private static func configure(_ descriptor: Int32) -> Bool {
        var on: Int32 = 1
        var timeout = timeval(tv_sec: writeTimeoutSeconds, tv_usec: 0)
        return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
            && setNonBlocking(descriptor, false)
    }

    // MARK: Serving one connection

    private func admitted(_ connection: Connection, _ admission: MCPGate.Admission) {
        guard running, !connection.closing, admission == .approved else {
            beginClose(connection)
            return
        }
        let (requests, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(Self.maxQueuedRequests))
        connection.requests = continuation

        let source = DispatchSource.makeReadSource(fileDescriptor: connection.descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readable(connection) }
        source.setCancelHandler { [weak self] in self?.sourceCancelled(connection) }
        connection.source = source
        source.resume()

        let handler = handler
        let gate = gate
        let key = connection.identity.key
        let queue = queue
        let server = self
        connection.consumer = Task {
            for await line in requests {
                // Approval is read live for every request: a revoke ends the conversation at the next message.
                guard await gate.isApproved(key: key) else { break }
                guard let response = await handler.respond(to: line) else { continue }
                guard await connection.write(response + Data([0x0A])) else { break }
            }
            // The stream ended (the client finished, so every answer was written) or the loop broke: either way, close.
            queue.async { server.beginClose(connection) }
        }
    }

    private func readable(_ connection: Connection) {
        guard !connection.closing, !connection.sawEnd else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { read(connection.descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { return }
            beginClose(connection)
            return
        }
        guard count > 0 else {
            // The client closed its sending side (the helper does this when its client ends). Stop reading, let queued
            // requests finish and be answered, then the consumer closes the connection.
            connection.sawEnd = true
            connection.requests?.finish()
            connection.source?.cancel()
            return
        }
        let output = connection.framer.feed(Data(buffer[0..<count]))
        for line in output.lines {
            if case .dropped? = connection.requests?.yield(line) {
                beginClose(connection)
                return
            }
        }
        if output.overflowed { beginClose(connection) }
    }

    // MARK: Closing

    /// Shuts a connection down, once. The descriptor itself is closed on the write queue, after any write in flight has
    /// failed fast (`shutdown`) and after the read source's cancel handler has run: a descriptor is never closed while a
    /// dispatch source or a writer might still use its number.
    private func beginClose(_ connection: Connection) {
        guard !connection.closing else { return }
        connection.closing = true
        shutdown(connection.descriptor, SHUT_RDWR)
        connection.requests?.finish()
        connection.consumer?.cancel()
        if let source = connection.source, !connection.sourceCancelled {
            source.cancel()  // the cancel handler continues in `sourceCancelled`
        } else {
            finishClose(connection)
        }
    }

    private func sourceCancelled(_ connection: Connection) {
        connection.sourceCancelled = true
        // An end-of-input cancel is not a close: the consumer is still answering. Close only once asked to.
        if connection.closing { finishClose(connection) }
    }

    private func finishClose(_ connection: Connection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.closeDescriptor()
    }
}

/// One accepted connection. The queue-confined fields are touched only on the server queue; `fdClosed` only on the write
/// queue, which is also the only place the descriptor is closed.
private final class Connection: @unchecked Sendable {
    let descriptor: Int32
    let identity: MCPClientIdentity
    private let writeQueue = DispatchQueue(label: "io.github.heilo27.Flotsam.mcp-write")
    private var fdClosed = false

    // Server-queue-confined.
    var source: DispatchSourceRead?
    var requests: AsyncStream<Data>.Continuation?
    var consumer: Task<Void, Never>?
    var framer = MCPLineFramer()
    var closing = false
    var sawEnd = false
    var sourceCancelled = false

    init(descriptor: Int32, identity: MCPClientIdentity) {
        self.descriptor = descriptor
        self.identity = identity
    }

    /// Writes every byte of `data`, or reports that it could not (a closed or stalled peer, or a connection being
    /// closed). Suspends the caller, not a thread of the server queue.
    func write(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            writeQueue.async {
                continuation.resume(returning: self.writeAll(data))
            }
        }
    }

    func closeDescriptor() {
        writeQueue.async {
            guard !self.fdClosed else { return }
            self.fdClosed = true
            close(self.descriptor)
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        guard !fdClosed else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress.map { $0 + offset }, raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                // A write that stays blocked past SO_SNDTIMEO fails with EAGAIN: the peer is not reading, so give up.
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
