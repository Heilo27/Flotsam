import Foundation

/// Who an MCP client is, as the system verified it (FR-010-04). Built by the app from the connecting process, never from
/// anything the client says about itself over the wire: a client can claim any `clientInfo.name`, it cannot claim another
/// program's code signature or path.
public struct MCPClientIdentity: Sendable, Equatable {
    /// The approval key (`MCPApproval.key`): signing identifier and team for a program signed by an Apple-issued
    /// certificate, else its executable path.
    public let key: String
    /// The name the prompt and the approvals list show: the app's name, else the program's file name.
    public let name: String
    /// What distinguishes two clients of one name: the signing identifier and team, or the path of an unsigned program.
    public let detail: String

    public init(key: String, name: String, detail: String) {
        self.key = key
        self.name = name
        self.detail = detail
    }
}
