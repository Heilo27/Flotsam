import Foundation
import FlotsamBase

/// What a hotkey does (FR-005-01). The registry is the only list of hotkeys; the item case is one per item.
public enum ShortcutID: Sendable, Hashable {
    case openLibrary
    case saveClipboard
    case toggleShelf
    case pasteQueue
    case item(UUID)

    var isItem: Bool {
        if case .item = self { return true }
        return false
    }

    /// Off while a Flotsam panel or the Settings window is key (FR-005-05, FR-003-25): the press would otherwise paste
    /// into Flotsam itself. An item hotkey and the paste-queue key act on the app in front, so both follow this rule.
    var suspendsWithFlotsamWindows: Bool { isItem || self == .pasteQueue }
}

/// Where a binding stands. `failed` keeps the chord and shows the warning badge (FR-005-03, TRG-OS-001).
public enum ShortcutStatus: Sendable, Equatable {
    case unbound
    case registered
    case failed
}

/// The only list of hotkeys and the only caller of the registrar (FR-005-01, FR-005-03, ADR-0006). A binding is kept
/// even when macOS refuses it, and registration is retried at launch, on wake and on re-save. A failed binding never
/// blocks another.
@MainActor
public final class ShortcutRegistry {
    private let registrar: any HotkeyRegistrar
    private let sink: any LogSink
    private let systemHotkeys: (any SystemHotkeyProvider)?
    private var bindings: [ShortcutID: Chord] = [:]
    private var actions: [ShortcutID: @MainActor () -> Void] = [:]
    private var registrations: [ShortcutID: HotkeyRegistration] = [:]
    private var failed: Set<ShortcutID> = []
    private var recorders = 0
    private var itemsSuspended = false

    public init(
        registrar: any HotkeyRegistrar, systemHotkeys: (any SystemHotkeyProvider)? = nil, sink: any LogSink = OSLogSink()
    ) {
        self.registrar = registrar
        self.sink = sink
        self.systemHotkeys = systemHotkeys
    }

    // MARK: Reading

    public func chord(for id: ShortcutID) -> Chord? { bindings[id] }

    public func status(of id: ShortcutID) -> ShortcutStatus {
        if failed.contains(id) { return .failed }
        return registrations[id] != nil ? .registered : .unbound
    }

    public var itemBindingCount: Int { bindings.keys.filter(\.isItem).count }

    // MARK: Validation (FR-005-02)

    /// Rules (a) to (d), then duplicates: `TRG-VAL-003` or `TRG-VAL-004`. `id` is the binding being edited, so
    /// re-saving its own chord is not a duplicate. Nothing is registered or saved here.
    public func validate(_ chord: Chord, for id: ShortcutID) -> FlotsamResult<Void> {
        if case .failure(let error) = ChordValidator.validate(chord, systemChords: systemHotkeys?.enabledSystemChords() ?? []) {
            return .failure(error)
        }
        if bindings.contains(where: { $0.key != id && $0.value == chord }) {
            return .failure(FlotsamError(.trgVal004, "Shortcut is already used in Flotsam"))
        }
        return .success(())
    }

    // MARK: Binding

    /// Sets what `id` does when its chord is pressed. The action is looked up at key-down, so it can be replaced.
    public func setAction(_ id: ShortcutID, _ action: @escaping @MainActor () -> Void) { actions[id] = action }

    /// Validates then binds `chord` (nil clears). A rejected chord changes nothing. A chord macOS refuses is kept with
    /// `.failed` status and returned as `TRG-OS-001` for the caller to surface; it is retried by `retryFailed()` and
    /// by binding again. `openLibrary` cannot be cleared (FR-005-01).
    @discardableResult
    public func bind(_ id: ShortcutID, to chord: Chord?) -> FlotsamResult<Void> {
        guard let chord else {
            if id == .openLibrary {
                return .failure(FlotsamError(.trgVal003, "The Library shortcut cannot be cleared"))
            }
            remove(id)
            return .success(())
        }
        if case .failure(let error) = validate(chord, for: id) { return .failure(error) }
        unregister(id)
        bindings[id] = chord
        return register(id)
    }

    /// Unregisters and forgets `id`'s chord (clear, item deleted). A global shortcut keeps its action, so binding it
    /// again later (the user records a new chord) works; an item's action goes with the item.
    public func remove(_ id: ShortcutID) {
        unregister(id)
        bindings[id] = nil
        if id.isItem { actions[id] = nil }
        failed.remove(id)
    }

    /// Loads the four global bindings from their settings (launch, and when a setting changes). A stored value that
    /// no longer validates is left unbound and reported through the return value, never crashing the load. With the
    /// Shelf turned off in Settings, `toggleShelf` is unregistered (FR-005-07); its setting is kept.
    @discardableResult
    public func applyGlobalSettings(_ settings: SettingsStore) -> [FlotsamError] {
        var errors: [FlotsamError] = []
        let wanted: [(ShortcutID, ChordBinding)] = [
            (.openLibrary, settings.value(SettingKeys.shortcutsOpenLibrary)),
            (.saveClipboard, settings.value(SettingKeys.shortcutsSaveClipboard)),
            (.toggleShelf, settings.value(SettingKeys.shortcutsToggleShelf)),
            (.pasteQueue, settings.value(SettingKeys.shortcutsPasteQueue)),
        ]
        for (id, binding) in wanted {
            let chord: Chord?
            switch binding {
            case .none: chord = nil
            case .chord(let value): chord = value
            }
            if chord == nil, id == .openLibrary { continue }
            if id == .toggleShelf, !settings.value(SettingKeys.shelfEnabled) {
                remove(id)
                continue
            }
            if case .failure(let error) = bind(id, to: chord) { errors.append(error) }
        }
        return errors
    }

    /// Makes the item hotkeys equal `wanted` (launch, and whenever items change, FR-005-22): hotkeys of items no longer
    /// listed come off, new or changed ones are bound with `action(itemId)`, and an unchanged one that macOS refused
    /// earlier is retried. A chord that fails validation or collides is skipped and returned; it never blocks the rest.
    @discardableResult
    public func syncItemHotkeys(
        _ wanted: [UUID: Chord], action: (UUID) -> @MainActor () -> Void
    ) -> [FlotsamError] {
        var errors: [FlotsamError] = []
        for id in bindings.keys {
            if case .item(let itemId) = id, wanted[itemId] == nil { remove(id) }
        }
        for itemId in wanted.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let chord = wanted[itemId] else { continue }
            let id = ShortcutID.item(itemId)
            if bindings[id] == chord, status(of: id) == .registered { continue }
            setAction(id, action(itemId))
            if case .failure(let error) = bind(id, to: chord) { errors.append(error) }
        }
        return errors
    }

    // MARK: Retry, recording, suspension

    /// Registers every kept binding that is not registered: at launch, on wake (FR-005-03). Returns the errors.
    @discardableResult
    public func retryFailed() -> [FlotsamError] {
        var errors: [FlotsamError] = []
        for id in failed.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            if case .failure(let error) = register(id) { errors.append(error) }
        }
        return errors
    }

    /// A recorder started: every global hotkey comes off so the recorder sees the chord (FR-005-04).
    public func beginRecording() {
        recorders += 1
        guard recorders == 1 else { return }
        registrar.unregisterAll()
        registrations.removeAll()
    }

    /// The recorder ended (any way): hotkeys go back on (FR-005-04).
    public func endRecording() {
        guard recorders > 0 else { return }
        recorders -= 1
        if recorders == 0 { reregisterAll() }
    }

    /// Item hotkeys and the paste-queue key are off while a Flotsam panel or the Settings window is key (FR-005-05).
    public func setItemHotkeysSuspended(_ suspended: Bool) {
        guard suspended != itemsSuspended else { return }
        itemsSuspended = suspended
        if suspended {
            for id in registrations.keys where id.suspendsWithFlotsamWindows { unregister(id) }
        } else {
            reregisterAll()
        }
    }

    /// Unregisters everything (quit, FR-005-03). Bindings stay, so `retryFailed` or a re-register can restore them.
    public func unregisterAll() {
        registrar.unregisterAll()
        registrations.removeAll()
    }

    // MARK: Internals

    private func reregisterAll() {
        for id in bindings.keys where registrations[id] == nil { _ = register(id) }
    }

    private func unregister(_ id: ShortcutID) {
        if let handle = registrations.removeValue(forKey: id) { registrar.unregister(handle) }
    }

    private func register(_ id: ShortcutID) -> FlotsamResult<Void> {
        guard let chord = bindings[id] else { return .success(()) }
        if recorders > 0 || (itemsSuspended && id.suspendsWithFlotsamWindows) { return .success(()) }
        unregister(id)
        let result = registrar.register(chord) { [weak self] in self?.actions[id]?() }
        switch result {
        case .success(let handle):
            registrations[id] = handle
            failed.remove(id)
            FlotsamLog.log(.hotkeyRegistered(outcome: .registered), sink: sink)
            return .success(())
        case .failure(let error):
            failed.insert(id)
            FlotsamLog.log(.hotkeyRegistered(outcome: .failed), sink: sink)
            return .failure(error)
        }
    }
}
