import AppKit
import Darwin
import FlotsamMCP
import Foundation
import Security

/// Who is on the other end of an MCP socket connection, as the operating system reports it (FR-010-04, ADR-0013).
/// Nothing here reads a byte the client sent: a client can call itself anything over the wire, it cannot choose its
/// process id, its code signature or its path.
///
/// The AI app does not connect directly. It launches the bundled `flotsam-mcp` helper, and the helper relays to the
/// socket, so the connecting process is the helper and the client the user approves is the helper's parent. A helper
/// whose parent has gone (it has been re-parented to launchd, process 1) is refused: there is no one to approve.
enum MCPPeerIdentity {
    /// The helper embedded in this app's bundle. Used by the settings pane (the path to give an AI app) and here (to
    /// recognise the helper), so the two cannot disagree.
    static var bundledHelperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/flotsam-mcp").path
    }

    /// The client behind `connection`, or nil when it cannot be identified or is not this user's: the connection is then
    /// refused.
    static func identify(connection descriptor: Int32) -> MCPClientIdentity? {
        guard isOwnedByCurrentUser(descriptor), let peer = peerProcessID(descriptor) else { return nil }
        guard var path = executablePath(of: peer) else { return nil }
        var process = peer
        if sameFile(path, bundledHelperPath) {
            // Approve the program that launched the helper, not the helper.
            guard let parent = parentProcessID(of: peer), parent > 1, let parentPath = executablePath(of: parent) else { return nil }
            process = parent
            path = parentPath
        }
        return identity(process: process, path: path)
    }

    // MARK: Process facts

    /// Same-user check. The socket file is 0600 in a 0700 folder so another user cannot reach it anyway; this is the
    /// second lock.
    private static func isOwnedByCurrentUser(_ descriptor: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(descriptor, &user, &group) == 0 && user == geteuid()
    }

    private static func peerProcessID(_ descriptor: Int32) -> pid_t? {
        var process: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &process, &length) == 0, process > 0 else { return nil }
        return process
    }

    private static func parentProcessID(of process: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func executablePath(of process: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(process, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sameFile(_ first: String, _ second: String) -> Bool {
        URL(fileURLWithPath: first).resolvingSymlinksInPath().path == URL(fileURLWithPath: second).resolvingSymlinksInPath().path
    }

    // MARK: Identity

    private static func identity(process: pid_t, path: String) -> MCPClientIdentity {
        let name = NSRunningApplication(processIdentifier: process)?.localizedName
            ?? URL(fileURLWithPath: path).lastPathComponent
        if let signed = appleIssuedSignature(of: process) {
            return MCPClientIdentity(key: "signed:\(signed.identifier):\(signed.team)", name: name, detail: "\(signed.identifier) (\(signed.team))")
        }
        // Unsigned, ad-hoc signed or self-signed: nothing stable vouches for it but where it lives.
        return MCPClientIdentity(key: "path:\(path)", name: name, detail: path)
    }

    /// The signing identifier and team of a running process whose signature chains to an Apple-issued certificate (an
    /// App Store, Developer ID or Apple-signed program), else nil. An ad-hoc or self-signed program does not satisfy
    /// `anchor apple generic`, so it cannot borrow a name: it is keyed by its path instead.
    private static func appleIssuedSignature(of process: pid_t) -> (identifier: String, team: String)? {
        var dynamic: SecCode?
        let attributes = [kSecGuestAttributePid: Int(process)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamic) == errSecSuccess, let dynamic else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
            let requirement, SecCodeCheckValidity(dynamic, [], requirement) == errSecSuccess
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamic, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let values = information as? [String: Any], let identifier = values[kSecCodeInfoIdentifier as String] as? String
        else { return nil }
        // Apple's own programs carry no team identifier; "apple" is the stable stand-in.
        return (identifier, values[kSecCodeInfoTeamIdentifier as String] as? String ?? "apple")
    }
}
