import AppKit
import FlotsamBase
import SwiftUI

/// The onboarding steps (FR-008-12). Every string is a catalogue key; status is always a word plus a symbol, never
/// colour alone (FR-008-17).
struct OnboardingView: View {
    let model: OnboardingModel
    let finish: () -> Void

    var body: some View {
        Group {
            if isPermissionStep { permissionLayout } else { standardLayout }
        }
        .padding(24)
        .frame(width: 560, height: 420)
        .refreshWhileVisible { model.refresh() }
    }

    /// A row of 8 pt dots centred above the title, one per step, the steps reached filled in the accent colour and the
    /// rest a visible grey, with a small "Step n of N" caption under them. VoiceOver reads the dots and caption as one
    /// element whose value is "Step n of N".
    private var stepCaption: some View {
        let progress = String(format: text("ui.onboarding.stepOf"), model.flow.position, model.flow.total)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                ForEach(1...model.flow.total, id: \.self) { index in
                    Circle()
                        .fill(index <= model.flow.position ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                }
            }
            Text(verbatim: progress)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text("ui.onboarding.windowTitle")))
        .accessibilityValue(Text(verbatim: progress))
    }

    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepCaption.padding(.bottom, 8)
            // Centred, like the permission steps' title and purpose, so every step's heading sits in the same place.
            Text(verbatim: text(model.step.titleKey))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity)
            Text(verbatim: text(model.step.purposeKey))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            content
            Spacer(minLength: 0)
            footer
        }
    }

    // MARK: Permission steps

    /// The three steps that ask for a permission (clipboard, Accessibility, Input Monitoring) share one centred layout:
    /// a symbol, the title and purpose, then either what is missing and how to fix it, or one line saying it is on.
    private var isPermissionStep: Bool {
        model.step == .clipboard || model.step == .accessibility || model.step == .inputMonitoring
    }

    /// Live status of the current permission step; false on every other step.
    private var permissionGranted: Bool {
        switch model.step {
        case .clipboard: model.pasteboardAllowed
        case .accessibility: model.accessibilityGranted
        case .inputMonitoring: model.inputMonitoringGranted
        default: false
        }
    }

    private var permissionLayout: some View {
        VStack(spacing: 16) {
            stepCaption
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Image(systemName: permissionSymbol)
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(verbatim: text(model.step.titleKey))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: text(model.step.purposeKey)).multilineTextAlignment(.center)
                permissionDetail.padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            footer
        }
    }

    private var permissionSymbol: String {
        switch model.step {
        case .clipboard: "doc.on.clipboard"
        case .accessibility: "accessibility"
        default: "keyboard"
        }
    }

    @ViewBuilder
    private var permissionDetail: some View {
        if permissionGranted {
            // Granted: the warning and the way to System Settings are moot, so one status line says what is now true and
            // Continue is the only prominent control. The green check belongs to this status alone.
            let line = text(grantedKey)
            // The text keeps the label colour (green text on white misses 4.5:1); the green check is the only colour.
            Label {
                Text(verbatim: line)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: [text(permissionNameKey), text("ui.onboarding.granted"), line].joined(separator: " ")))
        } else {
            Text(verbatim: text(missingKey)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            statusRow(permissionNameKey, granted: false)
            switch model.step {
            case .clipboard:
                Button(text("ui.onboarding.openSystemSettings")) { model.openPasteboardSettings() }
            case .accessibility:
                allowRow(allow: { model.allowAccessibility() }, open: { model.openSettings(for: .accessibility) })
            default:
                allowRow(allow: { model.allowInputMonitoring() }, open: { model.openSettings(for: .inputMonitoring) })
            }
        }
    }

    /// "Allow" asks the system; "Open System Settings" is the fallback, so it is demoted to a link.
    private func allowRow(allow: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Button(text("ui.onboarding.allow"), action: allow)
            Button(text("ui.onboarding.openSystemSettings"), action: open).buttonStyle(.link)
        }
    }

    private var permissionNameKey: String {
        switch model.step {
        case .clipboard: "ui.permission.pasteboard"
        case .accessibility: "ui.permission.accessibility"
        default: "ui.permission.inputMonitoring"
        }
    }

    private var grantedKey: String {
        switch model.step {
        case .clipboard: "ui.onboarding.clipboardGranted"
        case .accessibility: "ui.onboarding.accessibilityGranted"
        default: "ui.onboarding.inputMonitoringGranted"
        }
    }

    private var missingKey: String {
        switch model.step {
        case .clipboard: "ui.onboarding.clipboardMissing"
        case .accessibility: "ui.onboarding.accessibilityMissing"
        default: "ui.onboarding.inputMonitoringOptional"
        }
    }

    // MARK: Step content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            Text(verbatim: text("ui.onboarding.welcomeNetwork"))
        case .clipboard, .accessibility, .inputMonitoring:
            EmptyView()  // drawn by `permissionLayout`
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

    /// Read-only (FR-008-17): the pickup switch and the folder choice live in Settings › General, so this step shows the
    /// folder and offers only the one-time import.
    private var screenshotsContent: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: text("ui.onboarding.screenshotsMissing")).foregroundStyle(.secondary)
            HStack {
                Text(verbatim: text("ui.onboarding.screenshotFolder"))
                Text(verbatim: model.folderName ?? text("ui.onboarding.screenshotFolderDefault")).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
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

    /// Skip (Not Now on the permission steps) is a plain text button alone at the leading edge; Back and Continue sit together
    /// on the trailing edge, Continue the default (hill-climb r5). Step 4's "Not Now" is the visible default while the
    /// permission is missing, so Continue is not the default action there (FR-008-12); once it is granted, Continue is.
    private var footer: some View {
        let optionalStep = model.step == .accessibility || model.step == .inputMonitoring
        let notNowIsDefault = model.step == .inputMonitoring && !permissionGranted
        let skipTitle = text(optionalStep ? "ui.onboarding.notNow" : "ui.onboarding.skip")
        return HStack {
            if !model.flow.isLast, !notNowIsDefault {
                Button(skipTitle) { model.skip() }
                    .buttonStyle(.link)
            }
            Spacer()
            Button(text("ui.onboarding.back")) { model.back() }
                .disabled(model.flow.isFirst)
            if model.flow.isLast {
                Button(text("ui.onboarding.finish")) { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if notNowIsDefault {
                    Button(skipTitle) { model.skip() }
                        .keyboardShortcut(.defaultAction)
                }
                Button(text("ui.onboarding.continue")) { model.continueFromStep() }
                    .keyboardShortcut(notNowIsDefault ? nil : .defaultAction)
            }
        }
    }

    private func text(_ key: String) -> String { FlotsamStrings.text(forKey: key) ?? "" }
}
