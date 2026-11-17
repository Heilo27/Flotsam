import Foundation

/// Where a failure came from, which decides how it surfaces (FR-000-08).
public enum ErrorOrigin: Sendable, Equatable {
    /// The user did something and it failed (paste, hotkey, edit, drop, expansion): a HUD.
    case userInitiated
    /// Capture, screenshot pickup, retention and other work the user did not just ask for: a Notice and a badge.
    case background
}

/// The newest-first list behind menu bar, Notices (FR-000-08 b): at most 10, memory only.
struct NoticeBoard: Sendable, Equatable {
    static let capacity = 10
    private(set) var notices: [Notice] = []

    mutating func add(_ notice: Notice) {
        notices.insert(notice, at: 0)
        if notices.count > Self.capacity { notices.removeLast(notices.count - Self.capacity) }
    }

    mutating func removeAll() { notices.removeAll() }
}

/// FR-000-08 throttle: the same code surfaces at most once per 60 s and at most 3 HUDs per minute overall.
///
/// Why a rejected occurrence leaves no trace in the state: if a suppressed error reset the per-code timer, a fault
/// that fires every 20 s would never surface again after its first appearance. Only an occurrence that actually
/// surfaces counts.
struct SurfacingThrottle: Sendable {
    static let window: TimeInterval = 60
    static let maxHUDsPerWindow = 3

    private var lastSurfaced: [ErrorCode: Date] = [:]
    private var hudTimes: [Date] = []

    mutating func admit(_ code: ErrorCode, isHUD: Bool, now: Date) -> Bool {
        if let last = lastSurfaced[code], now.timeIntervalSince(last) < Self.window { return false }
        if isHUD {
            hudTimes.removeAll { now.timeIntervalSince($0) >= Self.window }
            if hudTimes.count >= Self.maxHUDsPerWindow { return false }
            hudTimes.append(now)
        }
        lastSurfaced[code] = now
        return true
    }
}

/// Every Warning, Error and Fatal passes through here: logged, recorded, then surfaced if the rules allow
/// (FR-000-08, FR-000-11 last clause, FR-000-13).
///
/// Why one actor: raises arrive from capture queues, the main thread and async tasks, and the throttle, the notice
/// list and the ring buffer must see them in one order. The actor serialises them without a lock and hops to the
/// main actor only to draw.
public actor ErrorReporter {
    private let presenter: any ErrorPresenter
    private let clock: any WallClock
    private var throttle = SurfacingThrottle()
    private var board = NoticeBoard()
    private var ring = ErrorRingBuffer()

    public init(presenter: any ErrorPresenter, clock: any WallClock = SystemClock()) {
        self.presenter = presenter
        self.clock = clock
    }

    /// Logs every severity; records and surfaces Warning, Error and Fatal. Logging and the ring buffer come first and
    /// are never throttled, so a throttled occurrence still appears in the log (AC-000-04).
    public func report(_ error: FlotsamError, origin: ErrorOrigin) async {
        let now = clock.now()
        FlotsamLog.log(error)

        switch error.severity {
        case .info:
            // Log only (FR-000-04). Not recorded: Info codes such as TRG-POL-001 fire per keystroke in a secure
            // field and would evict the Warning/Error history the diagnostics report exists to show (FR-000-13).
            return
        case .fatal:
            ring.record(RaisedError(code: error.code, severity: error.severity, timestamp: now))
            await presenter.presentFatal(error)
        case .warning, .error:
            ring.record(RaisedError(code: error.code, severity: error.severity, timestamp: now))
            guard throttle.admit(error.code, isHUD: origin == .userInitiated, now: now) else { return }
            let message = FlotsamStrings.message(for: error)
            switch origin {
            case .userInitiated:
                await presenter.showHUD(message: message)
            case .background:
                board.add(Notice(code: error.code, severity: error.severity, message: message, date: now))
                await presenter.noticesChanged(board.notices)
            }
        }
    }

    /// "Dismiss all" in the Notices menu (FR-000-08 b). Clears the list and so the badge.
    public func dismissAllNotices() async {
        board.removeAll()
        await presenter.noticesChanged([])
    }

    /// The ring buffer for the diagnostics report (FR-000-14).
    public func recentErrors() -> [RaisedError] { ring.entries }
}
