import Darwin
import FlotsamBase
import Foundation

/// `flotsam-mcp`: the program an AI client launches to talk to Flotsam over MCP's stdio transport (FRD-010, ADR-0013).
///
/// It is a byte relay and nothing else: standard input to the app's local socket, the socket to standard output. It
/// links FlotsamBase only, opens no database, parses no message and holds no clip. Who may read what is decided in the
/// app (the approval gate and the visibility gate); this process cannot widen it. If the app is not running, has local
/// AI access off, or has not approved the client that launched this, the connection is refused or closed and this
/// process exits.
///
/// It makes no network connection of any kind: the only socket it opens is the app's AF_UNIX socket in the data folder.
enum Relay {
    static func run() -> Int32 {
        guard case .success(let launch) = LaunchIsolation.fromProcess() else { return Exit.misconfigured }
        let path = MCPWire.socketURL(inFolder: launch.dataFolder).path
        signal(SIGPIPE, SIG_IGN)
        guard let socketFD = openSocket(path: path) else {
            diagnose("flotsam-mcp: cannot reach Flotsam. Open Flotsam and turn on Settings > Privacy > Local AI Access.")
            return Exit.unreachable
        }

        let finished = DispatchSemaphore(value: 0)
        // Socket to stdout. The app closing the connection (refused, revoked, or switched off) ends the relay.
        DispatchQueue.global(qos: .userInitiated).async {
            pump(from: socketFD, to: STDOUT_FILENO)
            finished.signal()
        }
        // Stdin to socket, on this thread. End of input means the client is done: tell the app, give it a moment to answer.
        pump(from: STDIN_FILENO, to: socketFD)
        shutdown(socketFD, SHUT_WR)
        _ = finished.wait(timeout: .now() + 2)
        close(socketFD)
        return Exit.ok
    }

    private enum Exit {
        static let ok: Int32 = 0
        static let unreachable: Int32 = 1
        static let misconfigured: Int32 = 2
    }

    private static func openSocket(path: String) -> Int32? {
        guard let address = MCPWire.unixAddress(path: path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = MCPWire.withSockaddr(address) { pointer, length in connect(descriptor, pointer, length) }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Copies until end of input or an error on either side.
    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            guard writeAll(destination, buffer, count: count) else { return }
        }
    }

    private static func writeAll(_ descriptor: Int32, _ buffer: [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { write(descriptor, $0.baseAddress.map { $0 + offset }, count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// One line on standard error, which MCP clients show in their server log. Never carries clip content.
    private static func diagnose(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

exit(Relay.run())
