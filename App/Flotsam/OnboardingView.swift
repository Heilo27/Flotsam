import AppKit
import FlotsamBase
import SwiftUI

/// The onboarding steps (FR-008-12). Every string is a catalogue key; status is always a word plus a symbol, never
/// colour alone (FR-008-17).
struct OnboardingView: View {
    let model: OnboardingModel
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: String(format: text("ui.onboarding.stepOf"), model.flow.position, model.flow.total))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: text(model.step.titleKey))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: text(model.step.purposeKey))
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 480, height: 380)
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    // MARK: Step content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            Text(verbatim: text("ui.onboarding.welcomeNetwork"))
        case .clipboard:
            Text(verbatim: text("ui.onboarding.clipboardMissing")).foregroundStyle(.secondary)
            statusRow("ui.permission.pasteboard", granted: model.pasteboardAllowed)
            Button(text("ui.onboarding.openSystemSettings")) { model.openPasteboardSettings() }
        case .accessibility:
            Text(verbatim: text("ui.onboarding.accessibilityMissing")).foregroundStyle(.secondary)
            statusRow("ui.permission.accessibility", granted: model.accessibilityGranted)
            HStack {
                Button(text("ui.onboarding.allow")) { model.allowAccessibility() }
                Button(text("ui.onboarding.openSystemSettings")) { model.openSettings(for: .accessibility) }
            }
        case .inputMonitoring:
            Text(verbatim: text("ui.onboarding.inputMonitoringOptional")).foregroundStyle(.secondary)
            statusRow("ui.permission.inputMonitoring", granted: model.inputMonitoringGranted)
            HStack {
                Button(text("ui.onboarding.allow")) { model.allowInputMonitoring() }
                Button(text("ui.onboarding.openSystemSettings")) { model.openSettings(for: .inputMonitoring) }
            }
        case .screenshots:
            screenshotsContent
        case .hotkey:
            hotkeyRow
        case .loginItem:
            loginItemContent
        case .done:
            Text(verbatim: text("ui.onboarding.doneHowTo"))
            Button(text("ui.onboarding.openLibrary")) { model.openLibrary() }
                .disabled(!model.canOpenLibrary)
        }
    }

    private var screenshotsContent: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: text("ui.onboarding.screenshotsMissing")).foregroundStyle(.secondary)
            Toggle(text("ui.onboarding.pickUpScreenshots"), isOn: $model.pickUpScreenshots)
            HStack {
                Text(verbatim: text("ui.onboarding.screenshotFolder"))
                Text(verbatim: model.folderName ?? text("ui.onboarding.screenshotFolderDefault")).foregroundStyle(.secondary)
                Button(text("ui.onboarding.chooseFolder")) { model.chooseFolder() }
            }
            .accessibilityElement(children: .contain)
            if let key = model.folderErrorKey {
                Text(verbatim: text(key)).foregroundStyle(.red).accessibilityLabel(text(key))
            }
            Toggle(text("ui.onboarding.importRecent"), isOn: $model.importRecent)
        }
    }

    /// The recorder is FRD-005's and is not built yet; until it lands this shows the chord only (FR-008-12 step 6).
    private var hotkeyRow: some View {
        let chord = model.openLibraryChord
        let shown: String
        switch chord {
        case .none: shown = text("ui.onboarding.hotkeyUnbound")
        case .chord(let value): shown = value.displayString
        }
        return HStack {
            Text(verbatim: text("ui.onboarding.hotkeyOpenLibrary"))
            Text(verbatim: shown).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var loginItemContent: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: text("ui.onboarding.loginItemMissing")).foregroundStyle(.secondary)
            Toggle(text("ui.onboarding.loginItemSwitch"), isOn: $model.launchAtLogin)
            if model.loginStatus == .requiresApproval {
                Text(verbatim: text("ui.onboarding.loginItemApproval")).foregroundStyle(.secondary)
                Button(text("ui.onboarding.openLoginItems")) { model.openLoginItemsSettings() }
            }
        }
    }

    private func statusRow(_ nameKey: String, granted: Bool) -> some View {
        let state = text(granted ? "ui.onboarding.granted" : "ui.onboarding.notGranted")
        let combined = "\(text(nameKey)), \(state)"
        return HStack {
            Image(systemName: granted ? "checkmark.circle" : "minus.circle").accessibilityHidden(true)
            Text(verbatim: text(nameKey))
            Text(verbatim: state).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: combined))
    }

    // MARK: Footer

    /// Step 4's "Not Now" is the visible default, so Continue is not the default action there (FR-008-12).
    private var footer: some View {
        let optionalStep = model.step == .accessibility || model.step == .inputMonitoring
        return HStack {
            Button(text("ui.onboarding.back")) { model.back() }
                .disabled(model.flow.isFirst)
            Spacer()
            if model.flow.isLast {
                Button(text("ui.onboarding.finish")) { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(text(optionalStep ? "ui.onboarding.notNow" : "ui.onboarding.skip")) { model.skip() }
                    .keyboardShortcut(model.step == .inputMonitoring ? .defaultAction : nil)
                Button(text("ui.onboarding.continue")) { model.continueFromStep() }
                    .keyboardShortcut(model.step == .inputMonitoring ? nil : .defaultAction)
            }
        }
    }

    private func text(_ key: String) -> String { FlotsamStrings.text(forKey: key) ?? "" }
}
