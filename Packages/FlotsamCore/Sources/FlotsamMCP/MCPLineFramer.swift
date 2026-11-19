import FlotsamBase
import Foundation

/// Splits a byte stream into newline-delimited messages (MCP stdio framing: one JSON-RPC message per line, no embedded
/// newlines). A message longer than `MCPWire.maxFrameBytes` is a protocol violation, not something to buffer: the
/// caller closes the connection, so a client cannot make the app hold unbounded memory.
public struct MCPLineFramer: Sendable {
    public struct Output: Sendable, Equatable {
        public var lines: [Data]
        /// True when the pending line exceeded the limit; the framer accepts nothing more.
        public var overflowed: Bool
    }

    private var buffer = Data()
    private var failed = false

    public init() {}

    public mutating func feed(_ bytes: Data) -> Output {
        guard !failed else { return Output(lines: [], overflowed: true) }
        buffer.append(bytes)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.count > MCPWire.maxFrameBytes {
                failed = true
                return Output(lines: lines, overflowed: true)
            }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if buffer.count > MCPWire.maxFrameBytes {
            failed = true
            buffer = Data()
        }
        return Output(lines: lines, overflowed: failed)
    }
}
