import FlotsamBase
import FlotsamStorage
import Foundation
import Observation

/// The state and decisions of the Clear History sheet (FR-007-11), lifted out of the SwiftUI view so `swift test` can
/// drive it (compiled into FlotsamAppModelTests by symlink): a range, an "include pinned and shortcut items" option
/// that starts off, the count that would go, and a Delete that stays disabled while nothing would be deleted or while
/// the count on screen is not the count for the range and option on screen.
@MainActor
@Observable
final class ClearHistoryModel {
    /// The popup's choices, in order.
    let ranges = ClearRange.allCases
    var range: ClearRange = .lastHour
    var includeExempt = false
    /// The last preview that landed and the (range, option) it was computed for. A preview only counts while its key
    /// is still the current one, so a count for an earlier choice is never shown or acted on.
    private(set) var preview: FlotsamResult<DeletionPreview>?
    private(set) var previewKey: PreviewKey?
    private(set) var deleting = false
    @ObservationIgnored private var latestRequest = 0
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

    /// The range and option the sheet shows right now. The view keys its preview task on this.
    var key: PreviewKey { PreviewKey(range: range, includeExempt: includeExempt) }

    /// True until a preview for the current range and option has landed (the sheet just opened, or the user changed a
    /// choice). While true there is no count to show and nothing to delete.
    var isCounting: Bool { previewKey != key }

    /// What Delete would remove, from the preview for the current range and option; 0 while counting or when the
    /// preview failed.
    var count: Int { isCounting ? 0 : ((try? preview?.get())?.count ?? 0) }

    /// True when the count for the current choice could not be read. It is not an empty range: Delete stays off and
    /// the text says so.
    var countFailed: Bool {
        guard !isCounting, case .failure = preview else { return false }
        return true
    }

    var countText: String {
        if isCounting { return SettingsString.clearCounting.text }
        if countFailed { return SettingsString.clearCountFailed.text }
        return count > 0 ? SettingsString.clearCount.text([.count(count)]) : SettingsString.clearNothing.text
    }

    var canDelete: Bool { count > 0 && !deleting }
    var deleteTitle: SettingsString { deleting ? .clearDeleting : .clearDelete }

    /// Re-reads the count for the current range and option. The view runs it whenever either changes. Every call
    /// starts by forgetting the landed count, so the count stays pending until this request's answer lands (returning
    /// to an earlier choice never shows its old count). A failed count is reported and shown as such. A result that
    /// arrives after the choice moved on, or after a newer request started, is dropped: only the newest request for
    /// the key still on screen may land, so a slow answer for an earlier choice cannot overwrite a newer one.
    func refreshPreview() async {
        latestRequest += 1
        let request = latestRequest
        let asked = key
        previewKey = nil
        let result = await storage.clearPreview(asked.range, asked.includeExempt)
        guard request == latestRequest, asked == key else { return }
        preview = result
        previewKey = asked
        if case .failure(let error) = result { report(error) }
    }

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

/// The choices a preview is computed for.
struct PreviewKey: Hashable, Sendable {
    let range: ClearRange
    let includeExempt: Bool
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
