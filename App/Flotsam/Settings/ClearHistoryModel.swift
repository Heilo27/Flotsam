import FlotsamBase
import FlotsamStorage
import Foundation
import Observation

/// The state and decisions of the Clear History sheet (FR-007-11), lifted out of the SwiftUI view so `swift test` can
/// drive it (compiled into FlotsamAppModelTests by symlink): a range, an "include pinned and shortcut items" option
/// that starts off, the count that would go, and a Delete that stays disabled while nothing would be deleted.
@MainActor
@Observable
final class ClearHistoryModel {
    /// The popup's choices, in order.
    let ranges = ClearRange.allCases
    var range: ClearRange = .lastHour
    var includeExempt = false
    private(set) var preview: FlotsamResult<DeletionPreview>?
    private(set) var deleting = false
    @ObservationIgnored private let storage: SettingsStorage
    @ObservationIgnored private let report: @MainActor @Sendable (FlotsamError) -> Void
    @ObservationIgnored private let hud: @MainActor @Sendable (String) -> Void
    @ObservationIgnored private let onClose: @MainActor () -> Void

    init(
        storage: SettingsStorage, report: @escaping @MainActor @Sendable (FlotsamError) -> Void,
        hud: @escaping @MainActor @Sendable (String) -> Void, onClose: @escaping @MainActor () -> Void
    ) {
        self.storage = storage
        self.report = report
        self.hud = hud
        self.onClose = onClose
    }

    /// What Delete would remove, from the last preview; 0 until one has loaded or when it failed.
    var count: Int { (try? preview?.get())?.count ?? 0 }

    var countText: String {
        count > 0 ? SettingsString.clearCount.text([.count(count)]) : SettingsString.clearNothing.text
    }

    var canDelete: Bool { count > 0 && !deleting }
    var deleteTitle: SettingsString { deleting ? .clearDeleting : .clearDelete }

    /// Re-reads the count for the current range and option. The view runs it whenever either changes.
    func refreshPreview() async { preview = await storage.clearPreview(range, includeExempt) }

    /// The Cancel button: closes the sheet and calls nothing that deletes.
    func cancel() { onClose() }

    /// The Delete button. Does nothing while `canDelete` is false (the button is disabled then too). Announces the
    /// number actually deleted, not the earlier preview, and closes the sheet whatever the outcome.
    @discardableResult
    func delete() -> Task<Void, Never> {
        guard canDelete else { return Task {} }
        deleting = true
        let range = range
        let includeExempt = includeExempt
        return Task {
            switch await storage.clear(range, includeExempt) {
            case .success(let outcome):
                hud(SettingsString.clearDone.text([.count(outcome.deletedCount)]))
            case .failure(let error):
                report(error)
            }
            deleting = false
            onClose()
        }
    }
}

extension ClearRange {
    /// The popup's label for each range (FR-007-11).
    var label: SettingsString {
        switch self {
        case .lastHour: .rangeLastHour
        case .last24Hours: .rangeLast24Hours
        case .allTime: .rangeAllTime
        }
    }
}
