import AppKit
import FlotsamBase
import FlotsamShortcuts
import Observation

/// One recorder's state (FR-005-04): captures the next chord while recording, shows a rejected one inline and keeps
/// recording. While any recorder records, the registry has every global hotkey off (`beginRecording`), so the chord
/// reaches this app instead of firing its action. The key events come from a local monitor, which sees only this
/// app's own events: no event tap, no permission.
@MainActor
@Observable
final class ShortcutRecorderModel {
    private(set) var isRecording = false
    /// The catalogue message of the last rejected chord; cleared when recording starts or ends.
    private(set) var errorMessage: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var registry: ShortcutRegistry?

    /// Starts capturing. `commit` receives the new binding: a valid chord, or `.none` for a clear (only when
    /// `allowClear`). The recorder stops itself after a commit, Esc, or `stop()`.
    func start(
        registry: ShortcutRegistry, id: ShortcutID, allowClear: Bool, commit: @escaping @MainActor (ChordBinding) -> Void
    ) {
        guard !isRecording else { return }
        isRecording = true
        errorMessage = nil
        self.registry = registry
        registry.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = Self.modifiers(of: event)
            MainActor.assumeIsolated {
                self?.handle(RecorderKey.interpret(keyCode: keyCode, modifiers: modifiers), id: id, allowClear: allowClear, commit: commit)
            }
            // Every key is consumed while recording, so a chord never reaches a menu or a text field.
            return nil
        }
    }

    /// Ends recording from outside (the view went away, the window lost focus). Safe to call when not recording.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        registry?.endRecording()
        registry = nil
    }

    private func handle(_ key: RecorderKey, id: ShortcutID, allowClear: Bool, commit: @MainActor (ChordBinding) -> Void) {
        guard isRecording else { return }
        switch key {
        case .cancel:
            stop()
        case .clear:
            // Where clearing is not allowed (FR-005-01) the key does nothing and recording continues.
            guard allowClear else { return }
            stop()
            commit(.none)
        case .chord(let chord):
            guard let registry else { return }
            switch registry.validate(chord, for: id) {
            case .success:
                stop()
                commit(.chord(chord))
            case .failure(let error):
                errorMessage = FlotsamStrings.message(for: error)
            }
        }
    }

    private static func modifiers(of event: NSEvent) -> ChordModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var result: ChordModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}
