import FlotsamBase

/// Keeps the global "open Library" hotkey registered (FR-003-01, FR-005-01). The chord comes from
/// `LibraryHotkeyPreferences` (the `shortcuts.openLibrary` setting).
@MainActor
final class LibraryHotkey {
    private let registrar: any HotkeyRegistrar
    private let preferences: any LibraryHotkeyPreferences
    private let toggleLibrary: @MainActor () -> Void
    private var registration: HotkeyRegistration?

    init(
        registrar: any HotkeyRegistrar,
        preferences: any LibraryHotkeyPreferences,
        toggleLibrary: @escaping @MainActor () -> Void
    ) {
        self.registrar = registrar
        self.preferences = preferences
        self.toggleLibrary = toggleLibrary
    }

    /// (Re)registers the current chord. Call at launch, on wake, and when the chord changes. A refused chord is
    /// returned (`TRG-OS-001`) so the caller can report it; the previous registration is released first either way.
    @discardableResult
    func apply() -> FlotsamResult<Void> {
        if let registration { registrar.unregister(registration) }
        registration = nil
        guard case .chord(let chord) = preferences.openLibraryChord else { return .success(()) }
        switch registrar.register(chord, handler: toggleLibrary) {
        case .success(let handle):
            registration = handle
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func stop() {
        if let registration { registrar.unregister(registration) }
        registration = nil
    }
}
