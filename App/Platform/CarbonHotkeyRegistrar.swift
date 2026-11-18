import Carbon.HIToolbox
import FlotsamBase

/// Four-character signature "FLTS" marks Flotsam's hotkeys.
private let carbonHotkeySignature: OSType = 0x464C_5453

/// Global hotkeys through Carbon `RegisterEventHotKey` (ADR-0006): no Accessibility or Input Monitoring needed.
/// One application event handler serves every registered hotkey; the handler looks the pressed hotkey up by id.
/// Ids are allocated per instance and all share the "FLTS" signature, so the app must hold exactly one instance
/// (`AppContainer.hotkeyRegistrar`); a second instance would reuse ids and answer for the first one's hotkeys.
@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private struct Entry {
        let reference: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextId: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    func register(_ chord: Chord, handler: @escaping @MainActor () -> Void) -> FlotsamResult<HotkeyRegistration> {
        guard installEventHandlerIfNeeded() else {
            return .failure(FlotsamError(.trgOs001, "The hotkey event handler could not be installed"))
        }
        let id = nextId
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(chord.keyCode), Self.carbonModifiers(chord.modifiers),
            EventHotKeyID(signature: carbonHotkeySignature, id: id),
            GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            return .failure(FlotsamError(.trgOs001, "The system refused the hotkey"))
        }
        nextId += 1
        entries[id] = Entry(reference: reference, handler: handler)
        return .success(HotkeyRegistration(rawValue: id))
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard let entry = entries.removeValue(forKey: registration.rawValue) else { return }
        UnregisterEventHotKey(entry.reference)
    }

    func unregisterAll() {
        for entry in entries.values { UnregisterEventHotKey(entry.reference) }
        entries.removeAll()
    }

    /// Dispatches a pressed hotkey. Called from the Carbon handler on the main thread. False when `id` is not one this
    /// registrar owns, so the event is left for other handlers.
    fileprivate func fire(id: UInt32) -> Bool {
        guard let entry = entries[id] else { return false }
        entry.handler()
        return true
    }

    /// `ChordModifiers` to Carbon modifier flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    static func carbonModifiers(_ modifiers: ChordModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), carbonHotkeyCallback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        return status == noErr
    }
}

/// Carbon delivers hotkey events on the main thread, so assuming main-actor isolation is sound here.
private func carbonHotkeyCallback(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyId = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId)
    guard status == noErr else { return status }
    guard hotKeyId.signature == carbonHotkeySignature else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    let handled = MainActor.assumeIsolated { registrar.fire(id: hotKeyId.id) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
