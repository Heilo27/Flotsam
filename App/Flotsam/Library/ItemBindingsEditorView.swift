import AppKit
import FlotsamBase
import SwiftUI

/// The shortcut-and-trigger editor's content (FR-005-09): a hotkey recorder, a trigger field for text-bearing kinds,
/// inline validation, and Save/Cancel. All text comes from the catalogue.
struct ItemBindingsEditorView: View {
    let model: ItemBindingsEditorModel
    let close: () -> Void
    /// Called with the clip's name once the item has loaded, so the window title can name it.
    var nameLoaded: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            case .gone:
                message(.editorItemGone)
            case .failed:
                message(.editorLoadFailed)
            case .ready, .saved:
                form
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await model.load() }
        // The recorder must not outlive the window or its focus: its hotkey suspension would stick (FR-005-04).
        .onDisappear { model.stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in model.stopRecording() }
        .onChange(of: model.clipName) { _, name in if let name { nameLoaded(name) } }
        .onChange(of: model.phase) { _, phase in if phase == .saved { close() } }
    }

    private func message(_ string: SettingsString) -> some View {
        VStack(alignment: .trailing, spacing: 14) {
            Text(string).frame(maxWidth: .infinity, alignment: .leading)
            Button(SettingsString.done.text, action: close).keyboardShortcut(.defaultAction)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 14) {
                hotkeyRow
                if model.triggerOffered {
                    triggerRow
                }
            }
            if !model.triggerOffered {
                Text(.editorNoTrigger).font(.caption).foregroundStyle(.secondary)
            }
            if let warning = model.warningMessage {
                Text(verbatim: warning).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(SettingsString.cancel.text, action: close).keyboardShortcut(.cancelAction)
                Button(SettingsString.editorSave.text) { Task { await model.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
    }

    /// Two aligned columns: right-aligned labels, then the control with its help under it.
    private var hotkeyRow: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(.editorShortcut).gridColumnAlignment(.trailing)
            HStack {
                ShortcutRecorderField(
                    chord: model.hotkey, recorder: model.recorder, allowClear: true, startRecording: model.startRecording,
                    clear: model.clearHotkey)
                Spacer(minLength: 0)
            }
        }
    }

    private var triggerRow: some View {
        @Bindable var model = model
        return GridRow(alignment: .firstTextBaseline) {
            Text(.editorTrigger)
            VStack(alignment: .leading, spacing: 4) {
                // Typed text is primary colour; only the empty field shows the dimmer placeholder.
                TextField(text: $model.triggerText, prompt: Text(.editorTriggerPlaceholder)) { Text(.editorTrigger) }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(.primary)
                    .disableAutocorrection(true)
                if let message = model.triggerErrorMessage {
                    Text(verbatim: message).font(.caption).foregroundStyle(.red)
                } else {
                    Text(.editorTriggerHelp).font(.caption).foregroundStyle(.secondary)
                }
                Text(.editorVariablesHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
