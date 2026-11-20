import FlotsamBase
import FlotsamPaste
import FlotsamShortcuts
import FlotsamStorage
import FlotsamTriggers
import Foundation
import Observation

/// What the shortcut-and-trigger editor needs from the app (FR-005-09). Closures keep the model free of the
/// database, the engine and the presenter, which `AppContainer` owns.
struct ItemBindingsEditorServices {
    let database: FlotsamDatabase
    let registry: ShortcutRegistry
    /// Called after a trigger was saved: the first saved trigger is when the permission prompts may appear (FR-005-10).
    let didSaveTrigger: @MainActor () async -> Void
    let report: @MainActor (FlotsamError) -> Void
    let hud: @MainActor (String) -> Void
}

/// One item's hotkey and trigger, edited together and saved together (FR-005-09). The hotkey recorder is
/// `ShortcutRecorderModel` (FR-005-04), so the rules a chord is held to are the Settings ones. Validation errors are
/// derived from the current input, shown inline and block saving; `TRG-VAL-005` is a warning and does not.
@MainActor
@Observable
final class ItemBindingsEditorModel {
    enum Phase: Equatable {
        case loading
        case ready
        /// The item was deleted while the editor was open (a racing sweep): nothing to edit.
        case gone
        case failed
        case saved
    }

    let itemId: UUID
    let recorder = ShortcutRecorderModel()
    private(set) var phase = Phase.loading
    /// Image, screenshot, file, folder and bundle items are not offered a trigger (FR-005-09).
    private(set) var triggerOffered = false
    private(set) var hotkey: Chord?
    /// What the clip is called in the window title: its first non-empty text line, else its first file's name, else its
    /// kind. Nil until the item is loaded (the title is then the generic one).
    private(set) var clipName: String?
    var triggerText = ""
    @ObservationIgnored private var storedHotkey: Chord?
    @ObservationIgnored private var storedTrigger: String?
    @ObservationIgnored private var otherTriggers: [String] = []
    @ObservationIgnored private var variableWarning: FlotsamError?
    @ObservationIgnored private let services: ItemBindingsEditorServices

    init(itemId: UUID, services: ItemBindingsEditorServices) {
        self.itemId = itemId
        self.services = services
    }

    // MARK: Derived state

    /// The trigger as it would be stored: empty text is "no trigger" (clearing the field removes the binding).
    private var pendingTrigger: String? { triggerOffered && !triggerText.isEmpty ? triggerText : nil }

    /// The inline catalogue message for the trigger field, nil when it is empty or valid. Uniqueness is checked against
    /// every other item's trigger; this item's own may be saved unchanged.
    var triggerErrorMessage: String? {
        guard let trigger = pendingTrigger else { return nil }
        if case .failure(let error) = TriggerGrammar.validate(trigger, among: otherTriggers) {
            return FlotsamStrings.message(for: error)
        }
        return nil
    }

    /// `TRG-VAL-005` (FR-005-17): the item's text holds a variable the expander does not know. Shown while the item
    /// would be pasted by a trigger or a hotkey; never blocks saving.
    var warningMessage: String? {
        guard let variableWarning, pendingTrigger != nil || hotkey != nil else { return nil }
        return FlotsamStrings.message(for: variableWarning)
    }

    var canSave: Bool { phase == .ready && triggerErrorMessage == nil && !recorder.isRecording }

    // MARK: Loading

    func load() async {
        async let content = services.database.content(of: itemId)
        async let bindings = services.database.itemBindings()
        switch (await content, await bindings) {
        case (.success(let content), .success(let bindings)):
            // A secure item takes no shortcut and no trigger (FR-005-09): the editor does not open for it. The menu
            // and ⌘K already stop here; this is the editor's own answer if one is opened some other way.
            guard !content.isSecure else {
                services.report(FlotsamError(.trgVal006, "A secure item cannot have a shortcut or trigger", context: [.itemId: .id(itemId)]))
                phase = .failed
                return
            }
            triggerOffered = content.kind.isTextBearing
            clipName = Self.name(of: content)
            storedHotkey = bindings.hotkeys[itemId]
            storedTrigger = bindings.triggers[itemId]
            hotkey = storedHotkey
            triggerText = triggerOffered ? (storedTrigger ?? "") : ""
            otherTriggers = bindings.triggers.filter { $0.key != itemId }.map(\.value)
            if triggerOffered, let text = content.plainText, case .failure(let error) = TemplateVariables.validate(text) {
                variableWarning = error
            }
            phase = .ready
        case (.failure(let error), _), (_, .failure(let error)):
            // An item removed before the editor opened reads as a failure; it is the same outcome for the user.
            services.report(error)
            phase = .failed
        }
    }

    /// The longest a clip name gets in a window title.
    private static let nameLimit = 80

    private static func name(of content: ItemContent) -> String {
        if let line = content.plainText?.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return line.count > nameLimit ? String(line.prefix(nameLimit)) + "…" : line
        }
        if let path = content.members.first?.path {
            let file = (path as NSString).lastPathComponent
            if !file.isEmpty { return file }
        }
        return KindLabel.text(for: content.kind)
    }

    // MARK: Hotkey

    func startRecording() {
        recorder.start(registry: services.registry, id: .item(itemId), allowClear: true) { [weak self] binding in
            switch binding {
            case .none: self?.hotkey = nil
            case .chord(let chord): self?.hotkey = chord
            }
        }
    }

    func stopRecording() { recorder.stop() }

    func clearHotkey() { hotkey = nil }

    // MARK: Saving

    /// Writes what changed through `applyExemptionEdit` (the one place the retention grace stamp is kept, FR-007-10).
    /// A trigger that was set triggers the engine's first-save permission prompt; clearing one does not, and the
    /// trigger snapshot rebuilds from the items-changed event the write publishes.
    func save() async {
        guard canSave else { return }
        let trigger = pendingTrigger
        if let hotkey, hotkey != storedHotkey, case .failure(let error) = services.registry.validate(hotkey, for: .item(itemId)) {
            // Another binding took the chord while the editor was open: keep the editor open so it can be changed.
            self.hotkey = storedHotkey
            services.hud(FlotsamStrings.message(for: error))
            return
        }
        if hotkey != storedHotkey {
            guard await apply(.setHotkey(hotkey)) else { return }
            storedHotkey = hotkey
        }
        if trigger != storedTrigger {
            guard await apply(.setTrigger(trigger)) else { return }
            storedTrigger = trigger
            if trigger != nil { await services.didSaveTrigger() }
        }
        if let variableWarning, trigger != nil || hotkey != nil { services.hud(FlotsamStrings.message(for: variableWarning)) }
        phase = .saved
    }

    /// False when the edit did not apply: the item is gone (phase `.gone`) or the write failed (reported, editor stays).
    private func apply(_ edit: ExemptionEdit) async -> Bool {
        switch await services.database.applyExemptionEdit(edit, to: itemId) {
        case .success(true): return true
        case .success(false):
            phase = .gone
            return false
        case .failure(let error):
            services.report(error)
            return false
        }
    }
}
