import FlotsamBase
import Foundation

/// Where the engine stands, for the menu-bar icon and the Triggers pane (FR-005-10, FR-005-19).
public enum TriggerEngineStatus: Sendable, Equatable {
    /// `triggers.enabled` is off. No tap.
    case off
    /// Enabled, but no item has a trigger. No tap and no keystroke observed.
    case idle
    /// Enabled with triggers, but a permission is missing. No tap. Carries `SET-PRM-001` and/or `SET-PRM-002`.
    case inert([ErrorCode])
    /// The tap is installed.
    case running
    /// The tap was disabled three times within 60 s and stays off until triggers are toggled off and on, or relaunch.
    case latchedOff
    /// The system refused to install the tap. Retried by the watchdog.
    case tapUnavailable(ErrorCode)
}

/// What the main-actor loop is told, from the tap thread, the item bus and the watchdog.
private enum EngineEvent: Sendable {
    case matched(TriggerMatch)
    case suppressed(TriggerSuppression)
    case tapDisabled(DisableVerdict)
    case rebuildSnapshot
    case reconcile
}

/// One installed tap's tap-thread state: the matcher and the way out to the main actor.
///
/// `@unchecked Sendable` because `TriggerMatcher` is deliberately not `Sendable` (mutable buffer, no lock). The
/// exception is safe by confinement (ADR-0007): the matcher is created here and handed to nothing else, and the
/// `KeyEventSource` contract runs `handler` and `onDisabled` on its one tap thread, so `handle` and `tapDisabled` never
/// overlap. A new session is built for every install, so a reinstalled tap starts with an empty word.
private final class TapSession: @unchecked Sendable {
    private let matcher: TriggerMatcher
    private let events: AsyncStream<EngineEvent>.Continuation

    init(matcher: TriggerMatcher, events: AsyncStream<EngineEvent>.Continuation) {
        self.matcher = matcher
        self.events = events
    }

    /// The tap callback (FR-005-21: no I/O). Matches and suppressions are handed to the main actor as values.
    func handle(_ event: KeyEvent) -> KeyDecision {
        let result = matcher.process(event)
        switch result {
        case .matched(let match): events.yield(.matched(match))
        case .suppressed(let suppression): events.yield(.suppressed(suppression))
        case .pass, .consume: break
        }
        return result.decision
    }

    /// The tap was disabled: the typed word is no longer trustworthy (FR-005-19).
    func tapDisabled() { matcher.reset() }
}

/// FR-005-10 and FR-005-19: decides whether the typed-trigger tap exists, keeps it healthy, and feeds matches to the
/// expander. Policy only: the `CGEventTap` itself is the `KeyEventSource` adapter (ADR-0007).
///
/// One serial loop on the main actor takes every event (matches, suppressions, disablements, item changes), so two
/// expansions never overlap and the snapshot is rebuilt in order. Everything that decides whether a tap should exist
/// is `reconcile()`: it runs after any change and on every watchdog pass, so a permission granted or revoked while
/// running installs or removes the tap within one watchdog interval (FR-005-19). The watchdog has no timer: it runs on
/// every 10th tick of the shared poll (`PollTick`, S5).
///
/// Permission prompts are raised only by `userDidSaveTrigger()` and `userDidEnableTriggers()`, never at launch
/// (FR-005-10). Call `stop()` when done: the loops hold the engine until then.
@MainActor
public final class TriggerEngine {
    private let source: any KeyEventSource
    private let snapshot: TriggerSnapshotStore
    private let bindings: any ItemBindingSource
    private let settings: SettingsStore
    private let bus: ItemEventBus
    private let expander: TriggerExpander
    private let keyboard: any KeyboardEnvironment
    private let permissions: any PermissionProbe
    private let reporter: ErrorReporter
    private let clock: any WallClock
    private let pollTick: PollTick
    private let resetSignal: TriggerResetSignal
    private let health: TapHealth
    private let ownBundleId: String

    private let events: AsyncStream<EngineEvent>
    private let eventSink: AsyncStream<EngineEvent>.Continuation
    /// True while a `.rebuildSnapshot` is queued, so a burst of item changes costs one rebuild.
    private let rebuildQueued = LockedValue(false)

    private var triggersEnabled = true
    private var isInstalled = false
    /// What was last reported, so a steady state is reported once per change and not on every watchdog pass.
    private var lastReportedMissing: [ErrorCode] = []
    private var lastReportedInstallFailure: ErrorCode?
    private var tasks: [Task<Void, Never>] = []
    private var cancelWatchdog: (@Sendable () -> Void)?
    private var unsubscribe: (@Sendable () -> Void)?
    private var hasStarted = false

    public private(set) var status: TriggerEngineStatus = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    /// Called on the main actor whenever `status` changes (menu-bar warning dot, Triggers pane).
    public var onStatusChange: ((TriggerEngineStatus) -> Void)?

    /// FR-005-19: the menu-bar icon warning dot is set while the tap is latched off. The latch (`TapHealth`) is the
    /// source of truth: revoking a permission or removing the last trigger moves `status` to `.inert`/`.idle`, but
    /// the latch persists until triggers are toggled off and on, so the dot holds.
    public var showsWarningDot: Bool { health.isLatched || status == .latchedOff }

    public init(
        source: any KeyEventSource, snapshot: TriggerSnapshotStore, bindings: any ItemBindingSource,
        settings: SettingsStore, bus: ItemEventBus, expander: TriggerExpander, keyboard: any KeyboardEnvironment,
        permissions: any PermissionProbe, reporter: ErrorReporter, clock: any WallClock,
        resetSignal: TriggerResetSignal, ownBundleId: String, pollTick: PollTick
    ) {
        self.source = source
        self.snapshot = snapshot
        self.bindings = bindings
        self.settings = settings
        self.bus = bus
        self.expander = expander
        self.keyboard = keyboard
        self.permissions = permissions
        self.reporter = reporter
        self.clock = clock
        self.pollTick = pollTick
        self.resetSignal = resetSignal
        self.health = TapHealth(clock: clock)
        self.ownBundleId = ownBundleId
        let stream = AsyncStream.makeStream(of: EngineEvent.self)
        self.events = stream.stream
        self.eventSink = stream.continuation
    }

    // MARK: Lifecycle

    /// Subscribes to settings and item events, builds the snapshot, decides whether a tap should exist, and starts the
    /// watchdog. Never prompts for a permission. Idempotent.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        // Subscribe before reading the current values, so a change in between is not lost.
        let enabledChanges = settings.changes(of: SettingKeys.triggersEnabled)
        let excludedChanges = settings.changes(of: SettingKeys.triggersExcludedApps)
        triggersEnabled = settings.value(SettingKeys.triggersEnabled)
        snapshot.setExcludedApps(Set(settings.value(SettingKeys.triggersExcludedApps).identifiers))

        let store = snapshot
        let eventSink = eventSink
        let rebuildQueued = rebuildQueued
        unsubscribe = bus.subscribe { event in
            switch event {
            case .itemsDeleted(let ids):
                // FR-005-22: the deleted trigger must stop expanding before the delete returns, so drop it inline.
                store.remove(itemIds: ids)
                eventSink.yield(.reconcile)
            case .itemsChanged:
                let wasQueued = rebuildQueued.withLock { queued -> Bool in
                    let was = queued
                    queued = true
                    return was
                }
                if !wasQueued { eventSink.yield(.rebuildSnapshot) }
            }
        }

        tasks = [
            Task { [weak self] in await self?.run() },
            Task { [weak self] in
                for await enabled in enabledChanges { await self?.setTriggersEnabled(enabled) }
            },
            Task { [weak self] in
                for await apps in excludedChanges { self?.snapshot.setExcludedApps(Set(apps.identifiers)) }
            },
        ]
        cancelWatchdog = pollTick.every(TriggerKeys.watchdogInterval) { [weak self] in
            Task { @MainActor in await self?.watchdogTick() }
        }

        await rebuildSnapshot()
    }

    /// Removes the tap and stops every loop.
    public func stop() {
        unsubscribe?()
        unsubscribe = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        cancelWatchdog?()
        cancelWatchdog = nil
        eventSink.finish()
        uninstall()
    }

    // MARK: User actions

    /// The user saved a trigger on an item. The first time one exists is when the permission prompts may appear
    /// (FR-005-10).
    public func userDidSaveTrigger() async {
        if triggersEnabled { requestMissingPermissions() }
        await rebuildSnapshot()
    }

    /// The user turned triggers on in Settings (FR-005-10). Call after the setting is stored.
    public func userDidEnableTriggers() async {
        requestMissingPermissions()
        await reconcileAndReport()
    }

    /// The system woke from sleep, or fast user switching came back to this session: clear the word and re-verify the
    /// tap now instead of at the next watchdog tick (FR-005-19).
    public func systemDidResume() async {
        resetSignal.request()
        await watchdogTick()
    }

    /// The frontmost application changed: clear the typed word (FR-005-11). The matcher also compares the application
    /// a word started in with the one at the boundary key, which catches a change this call has not reached yet;
    /// this call catches the one it cannot, a switch away and back mid-word. Call from `NSWorkspace`'s
    /// `didActivateApplicationNotification`.
    public func frontmostApplicationDidChange() {
        resetSignal.request()
    }

    // MARK: Watchdog (FR-005-19)

    /// One watchdog pass: finds a tap macOS disabled without telling us, then re-evaluates whether a tap should exist.
    ///
    /// A disablement found here counts toward the same limit as one reported by the tap's own callback. A tap that is
    /// disabled and re-enabled in the callback is healthy again before the watchdog looks, so the two paths do not
    /// double count except in a window of microseconds.
    func watchdogTick() async {
        var foundDisabled = false
        if isInstalled, !source.isHealthy {
            foundDisabled = true
            resetSignal.request()
            switch health.recordDisable() {
            case .reenable:
                // A tap that will not come back is replaced: `reconcile` installs a fresh one below.
                if !source.reenable() { uninstall() }
            case .latch:
                break  // `reconcile` removes it
            }
        }
        if foundDisabled {
            await reporter.report(FlotsamError(.trgOs003, "Event tap found disabled by the watchdog"), origin: .background)
        }
        await reconcileAndReport()
    }

    // MARK: The loop

    private func run() async {
        for await event in events {
            switch event {
            case .matched(let match):
                _ = await expander.expand(match)
            case .suppressed(let suppression):
                await report(suppression)
            case .tapDisabled(let verdict):
                await reporter.report(FlotsamError(.trgOs003, "Event tap disabled by the system"), origin: .background)
                if verdict == .latch { await reconcileAndReport() }
            case .rebuildSnapshot:
                rebuildQueued.withLock { $0 = false }
                await rebuildSnapshot()
            case .reconcile:
                await reconcileAndReport()
            }
        }
    }

    /// FR-005-13: only Secure Event Input and an excluded app are logged; an input method or an unknown app is silent.
    private func report(_ suppression: TriggerSuppression) async {
        switch suppression {
        case .secureInput:
            await reporter.report(FlotsamError(.trgPol001, "Secure input suppressed a trigger"), origin: .background)
        case .excludedApp:
            await reporter.report(FlotsamError(.trgPol002, "Excluded app suppressed a trigger"), origin: .background)
        case .inputMethod, .unknownApp:
            break
        }
    }

    // MARK: Snapshot and settings

    private func rebuildSnapshot() async {
        let token = snapshot.beginRebuild()
        switch await bindings.itemBindings() {
        case .success(let read):
            snapshot.replace(TriggerSnapshot(bindings: read), token: token)
        case .failure(let error):
            snapshot.abandonRebuild(token: token)
            // The previous snapshot stays: stale triggers still expand, which beats no triggers at all.
            await reporter.report(error, origin: .background)
        }
        await reconcileAndReport()
    }

    private func setTriggersEnabled(_ enabled: Bool) async {
        triggersEnabled = enabled
        // FR-005-19: toggling triggers off lifts the latch, so toggling them on again restores the tap.
        if !enabled { health.reset() }
        await reconcileAndReport()
    }

    private func requestMissingPermissions() {
        for kind in PermissionKind.allCases where !permissions.isGranted(kind) { permissions.request(kind) }
    }

    // MARK: Reconcile (FR-005-10)

    private func reconcileAndReport() async {
        for error in reconcile() { await reporter.report(error, origin: .background) }
    }

    /// Brings the tap in line with the four conditions of FR-005-10 plus the latch, and returns what to report.
    /// Synchronous on purpose: no suspension point between reading the conditions and acting on them, so two callers
    /// cannot interleave a half-made decision.
    private func reconcile() -> [FlotsamError] {
        guard triggersEnabled else { return settle(.off) }
        guard !snapshot.policy.triggers.isEmpty else { return settle(.idle) }

        let missing = TriggerPermissionNotice.missing(triggersEnabled: true, probe: permissions)
        guard missing.isEmpty else {
            let changed = missing != lastReportedMissing
            let reports = missing.map { FlotsamError($0, "Trigger permission missing") }
            _ = settle(.inert(missing))
            lastReportedMissing = missing  // after `settle`, which clears it for every other state
            return changed ? reports : []
        }
        lastReportedMissing = []

        guard !health.isLatched else { return settle(.latchedOff) }

        if !isInstalled {
            if let failure = install() {
                let changed = lastReportedInstallFailure != failure.code
                lastReportedInstallFailure = failure.code
                status = .tapUnavailable(failure.code)
                return changed ? [failure] : []
            }
            lastReportedInstallFailure = nil
        }
        status = .running
        return []
    }

    /// No tap should exist: remove it and set the status.
    private func settle(_ target: TriggerEngineStatus) -> [FlotsamError] {
        uninstall()
        lastReportedMissing = []
        lastReportedInstallFailure = nil
        status = target
        return []
    }

    // MARK: Tap

    private func install() -> FlotsamError? {
        let matcher = TriggerMatcher(
            store: snapshot, environment: keyboard, clock: clock, resetSignal: resetSignal, ownBundleId: ownBundleId)
        let session = TapSession(matcher: matcher, events: eventSink)
        let health = health
        let source = source
        let eventSink = eventSink
        let result = source.start(
            handler: { session.handle($0) },
            onDisabled: { _ in
                session.tapDisabled()
                let verdict = health.recordDisable()
                if verdict == .reenable { _ = source.reenable() }
                eventSink.yield(.tapDisabled(verdict))
            })
        switch result {
        case .success:
            isInstalled = true
            return nil
        case .failure(let error):
            return error
        }
    }

    private func uninstall() {
        guard isInstalled else { return }
        source.stop()
        isInstalled = false
    }
}
