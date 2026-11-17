import ApplicationServices
import CoreGraphics
import FlotsamBase
import FlotsamTriggers
import Foundation

/// The typed-trigger keyboard tap (FR-005-11, ADR-0007): an active session `CGEventTap` on key-down, key-up and mouse
/// down, run loop on its own thread so a slow handler can never stall the main thread. It decodes each event into a
/// `KeyEvent` value and applies the policy's decision; it holds no policy of its own.
///
/// `@unchecked Sendable`: the only mutable state is `installed`, guarded by `lock`. The Core Foundation objects in it
/// are only touched under the lock or on the tap thread that owns the run loop.
final class EventTapKeySource: KeyEventSource, @unchecked Sendable {
    /// What one installed tap owns. Retained context is released only after the tap thread has finished with it.
    private struct Installed {
        let tap: CFMachPort
        let runLoop: CFRunLoop
        let context: Unmanaged<TapContext>
        let finished: DispatchSemaphore
    }

    /// The handler pair the C callback reaches through `userInfo`.
    private final class TapContext: Sendable {
        let handler: @Sendable (KeyEvent) -> KeyDecision
        let onDisabled: @Sendable (TapDisableReason) -> Void

        init(
            handler: @escaping @Sendable (KeyEvent) -> KeyDecision,
            onDisabled: @escaping @Sendable (TapDisableReason) -> Void
        ) {
            self.handler = handler
            self.onDisabled = onDisabled
        }
    }

    /// Carries a Core Foundation reference into the tap thread's closure. Safe: each value is used by that one thread.
    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    private static let keyCodeField = CGEventField.keyboardEventKeycode
    private static let maxCharacters = 8
    private static let stopWait: DispatchTimeInterval = .seconds(1)

    private let resetSignal: TriggerResetSignal
    private let lock = NSLock()
    private var installed: Installed?

    init(resetSignal: TriggerResetSignal) { self.resetSignal = resetSignal }

    func start(
        handler: @escaping @Sendable (KeyEvent) -> KeyDecision,
        onDisabled: @escaping @Sendable (TapDisableReason) -> Void
    ) -> FlotsamResult<Void> {
        lock.lock()
        defer { lock.unlock() }
        if installed != nil { return .success(()) }

        let context = Unmanaged.passRetained(TapContext(handler: handler, onDisabled: onDisabled))
        let events: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: Self.callback, userInfo: context.toOpaque())
        else {
            context.release()
            return .failure(FlotsamError(.trgOs003, "The system refused to install the keyboard event tap"))
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            context.release()
            return .failure(FlotsamError(.trgOs003, "The keyboard event tap had no run loop source"))
        }

        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let loopBox = LockedValue<Unchecked<CFRunLoop>?>(nil)
        let source = Unchecked(value: runLoopSource)
        let machPort = Unchecked(value: tap)
        let thread = Thread {
            let runLoop: CFRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source.value, .commonModes)
            CGEvent.tapEnable(tap: machPort.value, enable: true)
            let loop = Unchecked(value: runLoop)
            loopBox.withLock { $0 = loop }
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source.value, .commonModes)
            finished.signal()
        }
        thread.name = "app.flotsam.trigger-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        guard let runLoop = loopBox.value?.value else {
            // Unreachable: the thread stores the run loop before signalling. Fail closed rather than crash.
            CFMachPortInvalidate(tap)
            context.release()
            return .failure(FlotsamError(.trgOs003, "The keyboard event tap thread did not start"))
        }
        installed = Installed(tap: tap, runLoop: runLoop, context: context, finished: finished)
        return .success(())
    }

    func stop() {
        lock.lock()
        let current = installed
        installed = nil
        lock.unlock()
        guard let current else { return }

        CGEvent.tapEnable(tap: current.tap, enable: false)
        CFMachPortInvalidate(current.tap)
        CFRunLoopStop(current.runLoop)
        // The callback may still be running; release its context only once the thread is done. On a timeout the
        // context is left allocated (a small leak) rather than freed under a running callback.
        if current.finished.wait(timeout: .now() + Self.stopWait) == .success { current.context.release() }
    }

    var isHealthy: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let installed else { return false }
        return CGEvent.tapIsEnabled(tap: installed.tap)
    }

    func reenable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let installed else { return false }
        // Whatever was typed before macOS switched the tap off is not trustworthy (FR-005-19).
        resetSignal.request()
        CGEvent.tapEnable(tap: installed.tap, enable: true)
        return CGEvent.tapIsEnabled(tap: installed.tap)
    }

    // MARK: Callback

    /// The C callback: no capture, reaches its state through `userInfo`. Runs on the tap thread (FR-005-21).
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout:
            context.onDisabled(.timeout)
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            context.onDisabled(.userInput)
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let decision = context.handler(decode(event, type: type))
            return decision == .consume ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static func decode(_ event: CGEvent, type: CGEventType) -> KeyEvent {
        let marked = event.getIntegerValueField(.eventSourceUserData) == FlotsamEventMarker.value
        switch type {
        case .keyDown, .keyUp:
            var length = 0
            var units = [UniChar](repeating: 0, count: maxCharacters)
            event.keyboardGetUnicodeString(maxStringLength: maxCharacters, actualStringLength: &length, unicodeString: &units)
            let characters = String(utf16CodeUnits: units, count: min(max(length, 0), maxCharacters))
            return KeyEvent(
                kind: type == .keyDown ? .keyDown : .keyUp,
                keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(keyCodeField)),
                flags: flags(of: event.flags), characters: characters,
                isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, isFlotsamEvent: marked)
        default:
            return KeyEvent(kind: .mouseDown, flags: flags(of: event.flags), isFlotsamEvent: marked)
        }
    }

    private static func flags(of flags: CGEventFlags) -> KeyEventFlags {
        var result: KeyEventFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlphaShift) { result.insert(.capsLock) }
        return result
    }
}
