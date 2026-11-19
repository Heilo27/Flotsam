import Foundation

/// The one home of what the in-app MCP server and its stdio helper agree on (FRD-010, ADR-0013). The helper links only
/// Base, so everything both ends must share lives here and nowhere else.
public enum MCPWire {
    /// The Unix-domain socket the app listens on, inside the data folder (0700). The file itself is 0600.
    public static let socketFileName = "mcp.sock"

    /// The longest line (one JSON-RPC message) either end accepts, in bytes. A longer line closes the connection.
    public static let maxFrameBytes = 1_048_576

    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, including the terminating zero.
    public static let maxSocketPathBytes = 103

    /// The MCP protocol revision the server speaks.
    public static let protocolVersion = "2025-06-18"

    public static func socketURL(inFolder folder: URL) -> URL {
        folder.appendingPathComponent(socketFileName)
    }

    /// The `AF_UNIX` address for a socket path, built in one place for both ends (the app binds it, the helper connects
    /// to it). Nil when the path does not fit in `sun_path`: a socket is never opened at a truncated path.
    public static func unixAddress(path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxSocketPathBytes else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        return address
    }

    /// Runs `body` with the address as the generic `sockaddr` pointer `bind` and `connect` take.
    public static func withSockaddr<Result>(
        _ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        var copy = address
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

/// One approved MCP client (FR-010-05): who it is as the system verified it (never what it called itself), and when the
/// user allowed it.
public struct MCPApproval: Codable, Sendable, Equatable {
    /// The stable identity key (FR-010-04): the code-signing identifier and team for a signed program, else its path.
    public let key: String
    /// What the approval list and the prompt call the client: the app's name, else the program's file name.
    public let name: String
    /// Where it runs from (a path) or who signed it, shown beside the name so two clients of one name are told apart.
    public let detail: String
    public let approvedAt: Date

    public init(key: String, name: String, detail: String, approvedAt: Date) {
        self.key = key
        self.name = name
        self.detail = detail
        self.approvedAt = approvedAt
    }
}

/// The persisted list of approved clients (`mcp.approvals`, FR-010-05). A client is approved if and only if its key is
/// here; revoking removes the entry.
public struct MCPApprovalList: SettingValue {
    public var approvals: [MCPApproval]

    public init(_ approvals: [MCPApproval]) { self.approvals = approvals }

    public static let empty = MCPApprovalList([])

    public init?(persisted: String) {
        guard let data = persisted.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([MCPApproval].self, from: data)
        else { return nil }
        self.approvals = decoded
    }

    public var persisted: String {
        // Encoding plain values cannot fail; the empty fallback keeps this non-throwing and fails closed (no approvals).
        guard let data = try? JSONEncoder().encode(approvals), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Keys are non-empty and unique, so a hand-edited list cannot approve a client twice or approve the empty identity.
    var isUsable: Bool {
        approvals.allSatisfy { !$0.key.isEmpty } && Set(approvals.map(\.key)).count == approvals.count
    }

    public func contains(key: String) -> Bool { approvals.contains { $0.key == key } }

    /// The list with `approval` added, replacing an entry of the same key.
    public func adding(_ approval: MCPApproval) -> MCPApprovalList {
        MCPApprovalList(approvals.filter { $0.key != approval.key } + [approval])
    }

    public func removing(key: String) -> MCPApprovalList {
        MCPApprovalList(approvals.filter { $0.key != key })
    }
}
