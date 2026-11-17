import FlotsamBase
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

    init(database: FlotsamDatabase) {
        usage = { await database.storageUsage() }
        retentionPreview = { await database.retentionPreview($0) }
        budgetPreview = { await database.imageBudgetEvictionPreview($0) }
        clearPreview = { await database.clearHistoryPreview(range: $0, includeExempt: $1) }
        clear = { await database.clearHistory(range: $0, includeExempt: $1) }
        sweep = { await database.runRetentionSweep(preset: $0, budget: $1) }
    }

    /// The database is not open (the Fatal path already told the user). Every call fails with `STO-DB-004`, which the
    /// window reports like any other read failure.
    static let unavailable: SettingsStorage = {
        let failure = FlotsamError(.stoDb004, "Settings storage is not available")
        return SettingsStorage(
            usage: { .failure(failure) }, retentionPreview: { _ in .failure(failure) },
            budgetPreview: { _ in .failure(failure) }, clearPreview: { _, _ in .failure(failure) },
            clear: { _, _ in .failure(failure) }, sweep: { _, _ in .failure(failure) })
    }()

    private init(
        usage: @escaping @Sendable () async -> FlotsamResult<StorageUsage>,
        retentionPreview: @escaping @Sendable (RetentionPreset) async -> FlotsamResult<DeletionPreview>,
        budgetPreview: @escaping @Sendable (ImageBudget) async -> FlotsamResult<DeletionPreview>,
        clearPreview: @escaping @Sendable (ClearRange, Bool) async -> FlotsamResult<DeletionPreview>,
        clear: @escaping @Sendable (ClearRange, Bool) async -> FlotsamResult<ClearOutcome>,
        sweep: @escaping @Sendable (RetentionPreset, ImageBudget) async -> FlotsamResult<SweepOutcome>
    ) {
        self.usage = usage
        self.retentionPreview = retentionPreview
        self.budgetPreview = budgetPreview
        self.clearPreview = clearPreview
        self.clear = clear
        self.sweep = sweep
    }
}

/// Everything the Settings window needs from the rest of the app, handed in by the composition root. The window holds
/// no keys, defaults or validation of its own: it reads and writes `settings` (FR-008-01) and asks the core for the rest.
struct SettingsEnvironment: Sendable {
    let settings: SettingsStore
    let login: LoginItemController
    let openLoginItems: @MainActor @Sendable () -> Void
    let permissions: any PermissionProbe
    let storage: SettingsStorage
    let dataFolder: URL
    /// Everything reported from Settings is a result of something the user just did, so the caller reports it as
    /// `ErrorOrigin.userInitiated` (a HUD).
    let report: @MainActor @Sendable (FlotsamError) -> Void
    let showSetupGuide: @MainActor @Sendable () -> Void
    /// Builds the diagnostics report and puts it on the pasteboard (FR-000-10); the result is the byte count copied.
    let copyDiagnostics: @Sendable () async -> FlotsamResult<Int>
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
