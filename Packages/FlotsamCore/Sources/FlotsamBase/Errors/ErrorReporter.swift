import Foundation

/// Where a failure came from, which decides how it surfaces (FR-000-08).
public enum ErrorOrigin: Sendable, Equatable {
    /// The user did something and it failed (paste, hotkey, edit, drop, expansion): a HUD.
    case userInitiated
    /// Capture, screenshot pickup, retention and other work the user did not just ask for: a Notice and a badge.
    case background
    /// The user's input was rejected and the view that took it shows the message in place (ORG-VAL, ORG-LIM, TRG-VAL):
    /// logged and recorded like any Warning or Error, but never a HUD or a Notice (FR-000-08 d).
    case inline
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

    /// Drops the notices of one code; true when any were there.
    mutating func remove(code: ErrorCode) -> Bool {
        let before = notices.count
        notices.removeAll { $0.code == code }
        return notices.count != before
    }
}

/// FR-000-08 throttle: the same code surfaces at most once per 60 s and at most 3 HUDs per minute overall.
///
/// Why a surfacing time ahead of `now` counts as expired: the wall clock can step backwards (NTP, a manual change,
/// resume from sleep). Read as a negative age it would suppress the code, and pin the HUD window full, until the clock
/// caught up, possibly hours. A user who sets the clock back would rather see one extra notice than have errors hidden.
///
/// Why a rejected occurrence leaves no trace in the state: if a suppressed error reset the per-code timer, a fault
/// that fires every 20 s would never surface again after its first appearance. Only an occurrence that actually
/// surfaces counts.
struct SurfacingThrottle: Sendable {
    static let window: TimeInterval = 60
    static let maxHUDsPerWindow = 3

    private var lastSurfaced: [ErrorCode: Date] = [:]
    private var hudTimes: [Date] = []

    /// True while a surfacing at `time` still counts: 0 <= age < 60 s. A time in the future (age < 0) has expired.
    private static func isLive(_ time: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(time)
        return age >= 0 && age < window
    }

    /// Forgets that `code` surfaced, so its next occurrence is a new one (FR-000-08: a cleared Notice restarts the clock).
    mutating func reset(_ code: ErrorCode) { lastSurfaced[code] = nil }

    mutating func admit(_ code: ErrorCode, isHUD: Bool, now: Date) -> Bool {
        if let last = lastSurfaced[code], Self.isLive(last, now: now) { return false }
        if isHUD {
            hudTimes.removeAll { !Self.isLive($0, now: now) }
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
    private let sink: any LogSink
    private var throttle = SurfacingThrottle()
    private var board = NoticeBoard()
    private var ring = ErrorRingBuffer()

    /// `sink` is the test seam for the FR-000-09/10 log contract: production logs to `os.Logger`, a test passes a
    /// recording sink and asserts the level, the public and private text and the cause of what `report` logged.
    public init(presenter: any ErrorPresenter, clock: any WallClock = SystemClock(), sink: any LogSink = OSLogSink()) {
        self.presenter = presenter
        self.clock = clock
        self.sink = sink
    }

    /// Logs every severity; records and surfaces Warning, Error and Fatal. Logging and the ring buffer come first and
    /// are never throttled, so a throttled occurrence still appears in the log (AC-000-04).
    public func report(_ error: FlotsamError, origin: ErrorOrigin) async {
        let now = clock.now()
        FlotsamLog.log(error, sink: sink)

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
            // The caller shows an inline message itself; surfacing it again would also spend the HUD throttle.
            guard origin != .inline else { return }
            guard throttle.admit(error.code, isHUD: origin == .userInitiated, now: now) else { return }
            let message = FlotsamStrings.message(for: error)
            switch origin {
            case .inline:
                return
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

    /// Removes the Notices of `code` once the condition behind them has ended (FRD-002 FR-002-03, FR-002-04: "the warning
    /// clears"). The owner of a long-lived condition calls this; the user's "Dismiss all" is separate. Does nothing
    /// when there is no such Notice, so the owner may call it on every recovery without checking. It also restarts that
    /// code's 60 s throttle: the condition ended, so the same condition returning is a new occurrence and shows again
    /// at once (FR-000-08, FR-001-18).
    public func clearNotices(code: ErrorCode) async {
        throttle.reset(code)
        guard board.remove(code: code) else { return }
        await presenter.noticesChanged(board.notices)
    }

    /// The ring buffer for the diagnostics report (FR-000-14).
    public func recentErrors() -> [RaisedError] { ring.entries }
}
