import AppKit
import FlotsamBase
import SwiftUI

/// The shortcut-and-trigger editor's content (FR-005-09): a hotkey recorder, a trigger field for text-bearing kinds,
/// inline validation, and Save/Cancel. All text comes from the catalogue.
struct ItemBindingsEditorView: View {
    let model: ItemBindingsEditorModel
    let close: () -> Void

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
            hotkeyRow
            if model.triggerOffered {
                triggerRow
            } else {
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

    private var hotkeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack {
                    if model.recorder.isRecording {
                        Text(.shortcutRecording).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: model.hotkey?.displayString ?? SettingsString.shortcutNotSet.text)
                        Button(SettingsString.shortcutRecord.text) { model.startRecording() }
                        if model.hotkey != nil {
                            Button(SettingsString.shortcutClear.text) { model.clearHotkey() }
                        }
                    }
                }
            } label: {
                Text(.editorShortcut)
            }
            if let message = model.recorder.errorMessage {
                Text(verbatim: message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var triggerRow: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                TextField(SettingsString.editorTriggerPlaceholder.text, text: $model.triggerText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            } label: {
                Text(.editorTrigger)
            }
            if let message = model.triggerErrorMessage {
                Text(verbatim: message).font(.caption).foregroundStyle(.red)
            } else {
                Text(.editorTriggerHelp).font(.caption).foregroundStyle(.secondary)
            }
            Text(.editorVariablesHelp).font(.caption).foregroundStyle(.secondary)
        }
    }
}
