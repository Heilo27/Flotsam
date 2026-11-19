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
///
/// How firmly each is identified differs, and ADR-0013 says so:
/// - The connecting process is named by its **audit token** (`LOCAL_PEERTOKEN`), which carries the process id and its
///   `pidversion`. The pidversion changes on every `exec`, so a process that connects and then execs something else no
///   longer matches its token, and the lookup by token (`kSecGuestAttributeAudit`) fails. A bare pid would not notice.
/// - The helper's parent is found by process id only: the kernel offers no audit token for a parent. It can be swapped
///   by an `exec` after the helper started. Identity through the helper is therefore a consent prompt, not a boundary
///   against same-user code (which can read the database file directly anyway).
enum MCPPeerIdentity {
    /// The helper's file name in `Contents/MacOS` and its product name in `project.yml`.
    private static let helperName = "flotsam-mcp"

    /// The helper embedded in this app's bundle. Used by the settings pane (the path to give an AI app) and here (to
    /// recognise the helper), so the two cannot disagree.
    static var bundledHelperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)").path
    }

    /// Signing identifiers that mean "the helper": the one the bundled helper carries, and the app's identifier plus
    /// `.mcp`, which is how `project.yml` names it. A program with either that is not the bundled file is a copy.
    private static let helperIdentifiers: Set<String> = {
        var identifiers: Set<String> = []
        if let app = Bundle.main.bundleIdentifier { identifiers.insert(app + ".mcp") }
        var staticCode: SecStaticCode?
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundledHelperPath) as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode, let identifier = signingInformation(of: staticCode)?[kSecCodeInfoIdentifier as String] as? String
        {
            identifiers.insert(identifier)
        }
        return identifiers
    }()

    /// A process whose identity has been established: its id, the path of its executable and its running code.
    private struct Process {
        let id: pid_t
        let path: String
        let code: SecCode
    }

    /// The client behind `connection`, or nil when it cannot be identified, is not this user's, or is a helper that is
    /// not the bundled one: the connection is then refused, with no prompt.
    static func identify(connection descriptor: Int32) -> MCPClientIdentity? {
        guard isOwnedByCurrentUser(descriptor), var token = peerToken(descriptor),
            // The token and the plain pid must agree; either alone can be stale.
            let peerID = peerProcessID(descriptor), processID(of: token) == peerID,
            let peer = process(token: &token)
        else { return nil }

        let client: Process
        if isHelper(peer) {
            // Only the helper in this bundle is a relay. A copy (its file name or its signing identifier is the helper's,
            // its path is not) would otherwise be offered to the user as a client, and approving it would admit every
            // caller of every copy: it is refused, and never recorded.
            guard sameFile(peer.path, bundledHelperPath), let parentID = parentProcessID(of: peerID), parentID > 1,
                let parent = process(id: parentID), !isHelper(parent)
            else { return nil }
            client = parent
        } else {
            client = peer
        }

        // Look again, after everything above was read: a process that exec'd in the meantime no longer matches its
        // token, and the path it ran from is no longer the one read.
        guard process(token: &token)?.path == peer.path, executablePath(of: client.id) == client.path,
            client.id == peer.id || parentProcessID(of: peerID) == client.id
        else { return nil }
        return identity(of: client)
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

    /// The connecting process's audit token: its process id and `pidversion`, fixed when it connected.
    private static func peerToken(_ descriptor: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
            length == socklen_t(MemoryLayout<audit_token_t>.size)
        else { return nil }
        return token
    }

    /// `audit_token_to_pid`: the sixth word of the token (the `libbsm` accessor is not imported into Swift).
    private static func processID(of token: audit_token_t) -> pid_t { pid_t(bitPattern: token.val.5) }

    /// The process an audit token names, or nil when no live process has that pid *and* that pidversion. The kernel does
    /// the comparison: a pid that was reused, or whose process has exec'd since, answers "no such code".
    private static func process(token: inout audit_token_t) -> Process? {
        let data = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
        var code: SecCode?
        let id = processID(of: token)
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
            let path = executablePath(of: id)
        else { return nil }
        return Process(id: id, path: path, code: code)
    }

    /// A process found by id alone: the helper's parent, for which the system offers no token (see the type's note).
    private static func process(id: pid_t) -> Process? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: Int(id)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
            let path = executablePath(of: id)
        else { return nil }
        return Process(id: id, path: path, code: code)
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

    // MARK: The helper

    /// Is this program the relay, or a copy of it? Judged by file name and by signing identifier, whatever the signature
    /// chains to, so a copy that is re-signed ad hoc or left as it was is still recognised. Whether it is the one in this
    /// bundle is a separate question (`sameFile`).
    private static func isHelper(_ process: Process) -> Bool {
        if URL(fileURLWithPath: process.path).lastPathComponent == helperName { return true }
        guard let identifier = signature(of: process.code)?.identifier else { return false }
        return helperIdentifiers.contains(identifier)
    }

    // MARK: Identity

    /// The identity to ask the user about, never a helper's: a helper is not a client, so no key is ever made for one.
    private static func identity(of process: Process) -> MCPClientIdentity? {
        guard !isHelper(process) else { return nil }
        let name = NSRunningApplication(processIdentifier: process.id)?.localizedName
            ?? URL(fileURLWithPath: process.path).lastPathComponent
        if let signed = signature(of: process.code), signed.isAppleIssued {
            return MCPClientIdentity(key: "signed:\(signed.identifier):\(signed.team)", name: name, detail: "\(signed.identifier) (\(signed.team))")
        }
        // Unsigned, ad-hoc signed or self-signed: nothing stable vouches for it but where it lives.
        return MCPClientIdentity(key: "path:\(process.path)", name: name, detail: process.path)
    }

    /// What a running program's code signature says about it. `isAppleIssued` is true only for a signature that chains to
    /// an Apple-issued certificate (an App Store, Developer ID or Apple-signed program, `anchor apple generic`): an
    /// ad-hoc or self-signed program does not satisfy it, so it cannot borrow a name and is keyed by its path instead.
    private struct Signature {
        let identifier: String
        let team: String
        let isAppleIssued: Bool
    }

    private static func signature(of code: SecCode) -> Signature? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            let values = signingInformation(of: staticCode), let identifier = values[kSecCodeInfoIdentifier as String] as? String
        else { return nil }
        var requirement: SecRequirement?
        let isAppleIssued = SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess
            && requirement.map { SecCodeCheckValidity(code, [], $0) == errSecSuccess } == true
        // Apple's own programs carry no team identifier; "apple" is the stable stand-in.
        return Signature(identifier: identifier, team: values[kSecCodeInfoTeamIdentifier as String] as? String ?? "apple", isAppleIssued: isAppleIssued)
    }

    private static func signingInformation(of staticCode: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return information as? [String: Any]
    }
}
