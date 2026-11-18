import Foundation
import FlotsamBase

/// Whether a visible Shelf hides by itself (transient) or only when told to (sticky), FR-006-04.
public enum ShelfRevealMode: Sendable, Equatable {
    case transient, sticky
}

public extension ShelfTrigger {
    /// Hotkey and menu reveals are sticky; drag, hover and menu-bar-icon-drag reveals are transient (FR-006-04).
    var mode: ShelfRevealMode {
        switch self {
        case .hotkey, .menuItem: .sticky
        case .drag, .hover, .menuBarIconDrag: .transient
        }
    }
}

/// When the Shelf shows and hides (FRD-006 FR-006-03, FR-006-04), as a pure value with no timers and no AppKit.
///
/// Why deadline-based and not timer-based: FR-006-17 requires no timers while the Shelf is idle. The machine never
/// schedules anything; it exposes `nextDeadline`, and the App layer arms one one-shot timer for it only while that is
/// non-nil, then calls `advance(to:)`. Every input carries its own `now`, so the tests run on a fixed clock and the
/// 300, 500 and 600 ms rules are asserted exactly.
///
/// The App layer reports what it sees (pointer region, drag state, button state, hotkey, clicks) as `Event`s and acts
/// on the returned `Command`s. Pointer reporting rule: whenever the Shelf is visible, the pointer is `.onShelf` while
/// it is inside the panel's frame, including at the moment the panel appears under it. A drag that starts from the
/// Shelf must send `.dragging(true)` too, so it cannot hide the panel mid-drag.
public struct ShelfRevealMachine: Sendable, Equatable {
    /// How long a drag must rest in an edge zone (or on the menu-bar icon) before the Shelf shows (FR-006-03a, d).
    public static let dragDwell: TimeInterval = 0.300
    /// How long the pointer must rest in the edge zone with hover reveal on (FR-006-03b).
    public static let hoverDwell: TimeInterval = 0.500
    /// How long a transient Shelf waits after the pointer leaves, or the drag ends, before it hides (FR-006-04).
    public static let hideDelay: TimeInterval = 0.600
    /// How long the Shelf stays after a successful drop (FR-006-15).
    public static let dropHold: TimeInterval = 1.5

    /// Where the pointer is. Screen indices are the App layer's, stable while the screen set is.
    public enum Pointer: Sendable, Equatable {
        case away
        case edgeZone(screen: Int)
        case menuBarIcon(screen: Int)
        case onShelf
    }

    public enum Event: Sendable, Equatable {
        case configure(enabled: Bool, placement: ShelfPlacement, revealOnEdgeHover: Bool)
        case pointer(Pointer)
        /// A drag session is in progress anywhere (own drag-outs included) or not.
        case dragging(Bool)
        /// A mouse button is down.
        case buttonDown(Bool)
        /// The reveal hotkey or the menu item. `screen` is the screen holding the pointer.
        case toggle(ShelfTrigger, screen: Int)
        case closeButton
        case escape
        case clickOutside
        /// A drag-out ended with an accepted operation (FR-006-11).
        case dragOutAccepted
        /// A card was pasted (FR-006-08, FR-006-09).
        case pasted
        /// A drop was processed and stored (FR-006-15).
        case dropCompleted
        case spaceChanged
        case libraryOpened
        case screensChanged
    }

    public enum Command: Sendable, Equatable {
        case show(trigger: ShelfTrigger, screen: Int)
        case hide
    }

    private struct Dwell: Sendable, Equatable {
        let trigger: ShelfTrigger
        let screen: Int
        let due: Date
    }

    private struct Visible: Sendable, Equatable {
        let trigger: ShelfTrigger
        let screen: Int
    }

    private var enabled = true
    private var placement: ShelfPlacement = .rightEdge
    private var revealOnEdgeHover = false
    private var pointer: Pointer = .away
    private var isDragging = false
    private var isButtonDown = false
    private var visible: Visible?
    private var dwell: Dwell?
    private var awaySince: Date?
    private var holdUntil: Date?
    /// Set when the Shelf hides with the pointer still in a zone, so it does not re-show until the pointer leaves.
    private var rearmOnLeave = false

    public init() {}

    public var isVisible: Bool { visible != nil }
    public var visibleTrigger: ShelfTrigger? { visible?.trigger }
    public var visibleScreen: Int? { visible?.screen }

    /// A transient Shelf never becomes key (FR-006-08); a sticky one may.
    public var canBecomeKey: Bool { visible?.trigger.mode == .sticky }

    /// The earliest moment `advance(to:)` has something to do, or `nil` when the machine is idle (FR-006-17).
    public var nextDeadline: Date? {
        [dwell?.due, hideDue].compactMap { $0 }.min()
    }

    /// Applies `event` at `now`. Deadlines at or before `now` fire first, at their own times.
    public mutating func send(_ event: Event, at now: Date) -> [Command] {
        var commands = advance(to: now)
        apply(event, at: now, into: &commands)
        reevaluate(at: now)
        return commands
    }

    /// Fires every deadline at or before `now`.
    public mutating func advance(to now: Date) -> [Command] {
        var commands: [Command] = []
        while let due = nextDeadline, due <= now {
            fire(at: due, into: &commands)
        }
        return commands
    }

    // MARK: Deadlines

    private var hideDue: Date? {
        guard let awaySince else { return nil }
        return max(awaySince, holdUntil ?? awaySince).addingTimeInterval(Self.hideDelay)
    }

    private mutating func fire(at due: Date, into commands: inout [Command]) {
        if let dwell, dwell.due <= due {
            self.dwell = nil
            visible = Visible(trigger: dwell.trigger, screen: dwell.screen)
            awaySince = nil
            holdUntil = nil
            commands.append(.show(trigger: dwell.trigger, screen: dwell.screen))
        } else {
            hide(into: &commands)
        }
        reevaluate(at: due)
    }

    // MARK: Events

    private mutating func apply(_ event: Event, at now: Date, into commands: inout [Command]) {
        switch event {
        case let .configure(enabled, placement, revealOnEdgeHover):
            let changed = enabled != self.enabled || placement != self.placement
            self.enabled = enabled
            self.placement = placement
            self.revealOnEdgeHover = revealOnEdgeHover
            if changed { hide(into: &commands) }
        case .pointer(let pointer):
            self.pointer = pointer
            if pointer == .away { rearmOnLeave = false }
        case .dragging(let dragging):
            isDragging = dragging
        case .buttonDown(let down):
            isButtonDown = down
        case let .toggle(trigger, screen):
            guard enabled else { return }
            if visible != nil {
                hide(into: &commands)
            } else {
                show(trigger, screen: screen, into: &commands)
            }
        case .closeButton, .escape:
            if visible?.trigger.mode == .sticky { hide(into: &commands) }
        case .clickOutside, .dragOutAccepted:
            if visible?.trigger.mode == .transient { hide(into: &commands) }
        case .pasted, .spaceChanged, .libraryOpened, .screensChanged:
            hide(into: &commands)
        case .dropCompleted:
            if visible != nil { holdUntil = now.addingTimeInterval(Self.dropHold) }
        }
    }

    private mutating func show(_ trigger: ShelfTrigger, screen: Int, into commands: inout [Command]) {
        visible = Visible(trigger: trigger, screen: screen)
        dwell = nil
        awaySince = nil
        holdUntil = nil
        commands.append(.show(trigger: trigger, screen: screen))
    }

    private mutating func hide(into commands: inout [Command]) {
        dwell = nil
        awaySince = nil
        holdUntil = nil
        guard visible != nil else { return }
        rearmOnLeave = pointer != .away
        visible = nil
        commands.append(.hide)
    }

    // MARK: Derived timers

    /// Starts, keeps or cancels the dwell and the leave timer to match the current inputs. A dwell keeps its start
    /// time while what it waits for stays the same, and restarts when the trigger or screen changes.
    private mutating func reevaluate(at now: Date) {
        if let wanted = wantedDwell() {
            if dwell?.trigger != wanted.trigger || dwell?.screen != wanted.screen {
                dwell = Dwell(trigger: wanted.trigger, screen: wanted.screen, due: now.addingTimeInterval(wanted.delay))
            }
        } else {
            dwell = nil
        }
        let wantsAway = visible?.trigger.mode == .transient && pointer != .onShelf && !isDragging
        if wantsAway {
            if awaySince == nil { awaySince = now }
        } else {
            awaySince = nil
        }
    }

    private func wantedDwell() -> (trigger: ShelfTrigger, screen: Int, delay: TimeInterval)? {
        guard enabled, visible == nil, !rearmOnLeave else { return nil }
        switch pointer {
        case .edgeZone(let screen) where placement != .menuBar:
            if isDragging { return (.drag, screen, Self.dragDwell) }
            if revealOnEdgeHover && !isButtonDown { return (.hover, screen, Self.hoverDwell) }
            return nil
        case .menuBarIcon(let screen) where placement == .menuBar && isDragging:
            return (.menuBarIconDrag, screen, Self.dragDwell)
        default:
            return nil
        }
    }
}
