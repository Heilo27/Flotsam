import Foundation

// Global hotkey ports (ADR-0006). The Carbon adapter lives in the app target's Platform folder; the chord model and
// validation (FR-005-02) live in Shortcuts. FRD-005 may extend these; it must not declare a second registrar.

/// Opaque handle for one registered hotkey, used to unregister it.
public struct HotkeyRegistration: Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

/// Registers system-wide hotkeys that need no Accessibility permission (FR-005-03).
@MainActor
public protocol HotkeyRegistrar {
    /// Registers `chord`; `handler` runs on the main actor at key-down. `TRG-OS-001` when the OS refuses.
    func register(_ chord: Chord, handler: @escaping @MainActor () -> Void) -> FlotsamResult<HotkeyRegistration>
    func unregister(_ registration: HotkeyRegistration)
    func unregisterAll()
}
