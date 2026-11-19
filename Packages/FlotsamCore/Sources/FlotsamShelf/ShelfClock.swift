import Foundation

/// Time for the Shelf's two timers (FR-006-15, FR-006-17): what "now" is, and how to wait. The App passes
/// `SystemShelfClock`; a test passes a clock it advances by hand, so a 600 ms highlight or a 1.5 s hold is asserted
/// without waiting.
public protocol ShelfClock: Sendable {
    var now: Date { get }
    /// Suspends for `seconds`. Never throws: on task cancellation it returns early (the `WallClock` contract), so a
    /// caller that must stop on cancellation checks `Task.isCancelled` after the call.
    func sleep(for seconds: TimeInterval) async
}

public struct SystemShelfClock: ShelfClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for seconds: TimeInterval) async {
        // Cancellation is the only error Task.sleep throws; the contract is to return early.
        try? await Task.sleep(for: .seconds(max(seconds, 0)))
    }
}

/// Drives `ShelfRevealMachine` from a `ShelfClock` (FR-006-17): events go in, the commands come out through `perform`,
/// and one one-shot task is armed for the machine's `nextDeadline` only while that is non-nil, cancelled and re-armed
/// after every event. Idle means no task.
@MainActor
public final class ShelfRevealDriver {
    public private(set) var machine = ShelfRevealMachine()
    private let clock: any ShelfClock
    private var deadlineTask: Task<Void, Never>?

    /// Receives the commands each event or deadline produces. Set once by the owner after it is built (the owner is
    /// what the commands act on, so it cannot be passed to `init`).
    public var perform: @MainActor ([ShelfRevealMachine.Command]) -> Void = { _ in }

    public init(clock: any ShelfClock = SystemShelfClock()) {
        self.clock = clock
    }

    /// True while a deadline timer is armed. False when the Shelf is idle (FR-006-17: no timers while idle).
    public var isTimerArmed: Bool { deadlineTask != nil }

    public func send(_ event: ShelfRevealMachine.Event) {
        let commands = machine.send(event, at: clock.now)
        perform(commands)
        arm()
    }

    private func arm() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = machine.nextDeadline else { return }
        let delay = max(deadline.timeIntervalSince(clock.now), 0)
        let clock = clock
        deadlineTask = Task { [weak self] in
            await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.deadlineReached()
        }
    }

    private func deadlineReached() {
        deadlineTask = nil
        perform(machine.advance(to: clock.now))
        arm()
    }
}

/// The card a drop stored or bumped stays highlighted for `ShelfLayout.dropHighlightDuration` (FR-006-15). A second
/// drop within that time keeps its own highlight: the first timer is cancelled, and `clearHighlight(of:)` only clears
/// the id it was given.
@MainActor
public final class ShelfHighlightTimer {
    private let model: ShelfModel
    private let clock: any ShelfClock
    private var task: Task<Void, Never>?

    public init(model: ShelfModel, clock: any ShelfClock = SystemShelfClock()) {
        self.model = model
        self.clock = clock
    }

    public var isTimerArmed: Bool { task != nil }

    public func highlight(_ itemId: UUID) {
        model.highlight(itemId)
        task?.cancel()
        let clock = clock
        task = Task { [weak self] in
            await clock.sleep(for: ShelfLayout.dropHighlightDuration)
            guard !Task.isCancelled else { return }
            self?.expired(itemId)
        }
    }

    private func expired(_ itemId: UUID) {
        task = nil
        model.clearHighlight(of: itemId)
    }
}
