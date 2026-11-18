import FlotsamBase
import FlotsamShortcuts
import FlotsamStorage
import Foundation
import Observation
import SwiftUI

/// The Storage calls the Settings window makes, as closures, so the window does not own or open the database and the
/// composition root decides which database it talks to (FRD-007). Every call is async and returns a `FlotsamResult`.
struct SettingsStorage: Sendable {
    var usage: @Sendable () async -> FlotsamResult<StorageUsage>
    var retentionPreview: @Sendable (RetentionPreset) async -> FlotsamResult<DeletionPreview>
    var budgetPreview: @Sendable (ImageBudget) async -> FlotsamResult<DeletionPreview>
    var clearPreview: @Sendable (ClearRange, Bool) async -> FlotsamResult<DeletionPreview>
    var clear: @Sendable (ClearRange, Bool) async -> FlotsamResult<ClearOutcome>
    var sweep: @Sendable (RetentionPreset, ImageBudget) async -> FlotsamResult<SweepOutcome>

    /// `database` is asked on every call, because the database opens after launch and may not be open yet when the
    /// window is built; while it is nil every call fails with `STO-DB-004`.
    init(database: @escaping @MainActor @Sendable () -> FlotsamDatabase?) {
        let missing = FlotsamError(.stoDb004, "Settings storage is not available")
        usage = { guard let db = await database() else { return .failure(missing) }; return await db.storageUsage() }
        retentionPreview = { preset in
            guard let db = await database() else { return .failure(missing) }
            return await db.retentionPreview(preset)
        }
        budgetPreview = { budget in
            guard let db = await database() else { return .failure(missing) }
            return await db.imageBudgetEvictionPreview(budget)
        }
        clearPreview = { range, exempt in
            guard let db = await database() else { return .failure(missing) }
            return await db.clearHistoryPreview(range: range, includeExempt: exempt)
        }
        clear = { range, exempt in
            guard let db = await database() else { return .failure(missing) }
            return await db.clearHistory(range: range, includeExempt: exempt)
        }
        sweep = { preset, budget in
            guard let db = await database() else { return .failure(missing) }
            return await db.runRetentionSweep(preset: preset, budget: budget)
        }
    }
}

/// Everything the Settings window needs from the rest of the app, handed in by the composition root. The window holds
/// no keys, defaults or validation of its own: it reads and writes `settings` (FR-008-01) and asks the core for the rest.
struct SettingsEnvironment: Sendable {
    let settings: SettingsStore
    let login: LoginItemController
    let openLoginItems: @MainActor @Sendable () -> Void
    let permissions: any PermissionProbe
    /// The one hotkey registry (FR-005-01): the Shortcuts pane's recorder validates against it and suspends it.
    let shortcuts: ShortcutRegistry
    let storage: SettingsStorage
    let dataFolder: URL
    /// Opens the data folder in Finder (the Fatal alert reveals the same folder).
    let revealDataFolder: @MainActor @Sendable () -> Void
    /// Everything reported from Settings is a result of something the user just did, so the caller reports it as
    /// `ErrorOrigin.userInitiated` (a HUD).
    let report: @MainActor @Sendable (FlotsamError) -> Void
    /// The one-line HUD for a result that is not an error ("Diagnostics copied", "{n} items deleted").
    let hud: @MainActor @Sendable (String) -> Void
    /// TODO(FRD-008 menu/onboarding builder): reopens onboarding (FR-008-12). Seam until that window exists.
    let showSetupGuide: @MainActor @Sendable () -> Void
    /// FR-002-12: the same action onboarding calls; it shows the "Imported {n}" HUD itself. Read at click time, because
    /// pickup is wired after the database opens, which can be after this environment is built.
    let importRecentScreenshots: @MainActor @Sendable () -> Void
    /// Builds the diagnostics report and puts it on the pasteboard (FR-000-10); the result is the byte count copied.
    let copyDiagnostics: @Sendable () async -> FlotsamResult<Int>
}

extension SettingsEnvironment {
    /// The project page, opened only when the user clicks "Project Page" (FR-008-09). Never fetched.
    static let projectPageURL = URL(string: "https://github.com/Heilo27/Flotsam") ?? URL(fileURLWithPath: "/")
}

/// What the pane views share: the environment, and a revision that moves whenever any setting changes, so a view that
/// read a value through `binding(_:)` redraws when the value changes from anywhere (a menu, the Library, a reset).
@MainActor
@Observable
final class SettingsModel {
    let env: SettingsEnvironment
    private(set) var revision = 0
    @ObservationIgnored private var unsubscribe: (@Sendable () -> Void)?

    init(env: SettingsEnvironment) {
        self.env = env
        unsubscribe = env.settings.subscribe { [weak self] _ in
            Task { @MainActor in self?.revision += 1 }
        }
    }

    /// A two-way binding to one registry key. Writing goes through `SettingsStore.set`, the only writer, so the change
    /// is delivered to every subscriber.
    func binding<Value: SettingValue>(_ key: SettingKey<Value>) -> Binding<Value> {
        Binding(
            get: { MainActor.assumeIsolated { _ = self.revision; return self.env.settings.value(key) } },
            set: { newValue in MainActor.assumeIsolated { self.env.settings.set(newValue, for: key) } })
    }

    /// The current value, read so that a view calling this redraws when it changes.
    func value<Value: SettingValue>(_ key: SettingKey<Value>) -> Value {
        _ = revision
        return env.settings.value(key)
    }
}

extension Text {
    /// Catalogue text for a Settings string (FR-000-05): views never pass literals.
    init(_ string: SettingsString) { self.init(verbatim: string.text) }
}
