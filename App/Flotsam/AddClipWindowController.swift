import AppKit
import FlotsamBase
import Observation
import SwiftUI

/// The Add Clip window (FR-004-19): a multi-line text field that stores what is typed as a text clip, so a trigger or
/// hotkey can be given to text that was never copied. One window; opening it again brings it forward. ⌘Return adds,
/// Esc and ⌘W close without adding. Storing is `add` (Capture's ingest path), never a second insert.
@MainActor
final class AddClipWindowController: NSObject, NSWindowDelegate {
    private let model: AddClipModel
    private var window: NSWindow?
    private var front: WindowFrontAdapter?

    init(
        add: @escaping @MainActor (String) async -> FlotsamResult<Void>,
        report: @escaping @MainActor (FlotsamError) -> Void,
        hud: @escaping @MainActor (String) -> Void
    ) {
        model = AddClipModel(add: add, report: report, hud: hud)
        super.init()
    }

    func open() {
        if let front {
            front.bringToFront()
            return
        }
        model.reset()
        let host = NSHostingController(rootView: AddClipView(model: model) { [weak self] in self?.close() })
        host.sizingOptions = [.preferredContentSize]
        let window = EditorWindow(contentViewController: host)
        window.title = SettingsString.addClipWindow.text
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        // Opened from a hotkey or the menu bar, from any app: the window must bring Flotsam forward itself.
        let front = WindowFrontAdapter(window: window)
        self.front = front
        front.bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        front = nil
    }

    private func close() {
        let old = window
        window = nil
        front = nil
        old?.delegate = nil
        old?.close()
    }
}

/// The text being typed and the outcome of adding it. A rejection stays in the window as an inline catalogue message
/// (the code is logged and recorded, never a HUD, FR-000-08 d); success closes the window with a HUD.
@MainActor
@Observable
final class AddClipModel {
    var text = ""
    private(set) var errorMessage: String?
    private(set) var isAdding = false
    @ObservationIgnored private let add: @MainActor (String) async -> FlotsamResult<Void>
    @ObservationIgnored private let report: @MainActor (FlotsamError) -> Void
    @ObservationIgnored private let hud: @MainActor (String) -> Void

    init(
        add: @escaping @MainActor (String) async -> FlotsamResult<Void>,
        report: @escaping @MainActor (FlotsamError) -> Void,
        hud: @escaping @MainActor (String) -> Void
    ) {
        self.add = add
        self.report = report
        self.hud = hud
    }

    /// Whether Add is offered: some visible text, and no add in flight. The full rule (and the ceiling) is applied by
    /// the store, so this only stops the obvious empty press.
    var canAdd: Bool { !isAdding && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func reset() {
        text = ""
        errorMessage = nil
        isAdding = false
    }

    /// Adds the text. Returns true when it was stored, which is when the window closes.
    func addClip() async -> Bool {
        guard canAdd else { return false }
        isAdding = true
        defer { isAdding = false }
        switch await add(text) {
        case .success:
            hud(SettingsString.addClipDone.text)
            return true
        case .failure(let error):
            errorMessage = FlotsamStrings.message(for: error)
            report(error)
            return false
        }
    }
}

private struct AddClipView: View {
    let model: AddClipModel
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text(.addClipHelp).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .fieldChrome(isActive: focused)
                .frame(minHeight: 140)
                .accessibilityLabel(SettingsString.addClipWindow.text)
            if let message = model.errorMessage {
                Text(verbatim: message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(SettingsString.cancel.text, action: close).keyboardShortcut(.cancelAction)
                Button(SettingsString.addClipSave.text) {
                    Task { if await model.addClip() { close() } }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canAdd)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}
