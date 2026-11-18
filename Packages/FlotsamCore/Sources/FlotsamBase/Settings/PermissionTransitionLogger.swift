import Foundation

/// Logs a permission going from granted to denied or back (FR-000-11, `permission.changed`). It remembers the last
/// state it saw per permission and logs only a change, so the line means "this flipped", not "this was checked". The
/// first look at a permission only records a baseline: launching with a permission already granted is not a change.
///
/// The probe is read fresh each time and nothing is cached for decisions (FR-008-13 rule b); the remembered state
/// exists only to tell a transition from a repeat. The app calls `check` at launch and whenever it becomes active,
/// which is when the user returns from System Settings.
@MainActor
public final class PermissionTransitionLogger {
    private let probe: any PermissionProbe
    private let sink: any LogSink
    private var lastSeen: [PermissionKind: Bool] = [:]

    public init(probe: any PermissionProbe, sink: any LogSink = OSLogSink()) {
        self.probe = probe
        self.sink = sink
    }

    /// Reads every permission once and logs each one whose state differs from the last read.
    public func check() {
        for kind in PermissionKind.allCases {
            let granted = probe.isGranted(kind)
            defer { lastSeen[kind] = granted }
            guard let previous = lastSeen[kind], previous != granted else { continue }
            FlotsamLog.log(.permissionChanged(Self.name(of: kind), granted: granted), sink: sink)
        }
    }

    /// The one place a probe kind becomes the log's closed permission name.
    private static func name(of kind: PermissionKind) -> PermissionName {
        switch kind {
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        }
    }
}
