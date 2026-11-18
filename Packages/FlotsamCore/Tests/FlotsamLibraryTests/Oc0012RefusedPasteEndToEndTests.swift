import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-470, FRD-000 OC-0012 (FR-000-04, FR-000-08), the whole chain: Return in the Library, the shipping PasteService
// writing the general pasteboard (PasteboardPort fake) and being refused at the ⌘V post, the Library reporting LIB-OS-001,
// and the shipping ErrorReporter drawing it. ErrorReporterTests holds the reporter half in isolation; this holds the
// half the oracle's `then` also names: the item is on the pasteboard and the process stays alive.
//
// What a package test cannot see: the HUD's pixels and the real Accessibility refusal of a real target app (running
// app, manual). The `.userInitiated` origin below is the App's own wiring (AppContainer, `LibraryEffects.report`),
// which no package test can import; it is the one line this test restates.

@MainActor
private final class HUDPresenter: ErrorPresenter {
    private(set) var huds: [String] = []
    private(set) var notices: [Notice] = []
    private(set) var fatals: [FlotsamError] = []
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) { self.notices = notices }
    func presentFatal(_ error: FlotsamError) { fatals.append(error) }
}

/// The target app refusing the synthetic ⌘V (`refuses`), then accepting it.
@MainActor
private final class RefusingKeys: KeyEventPoster {
    var refuses = true
    private(set) var attempts = 0
    private(set) var delivered = 0
    func postPaste(to target: FrontmostApp) -> Bool {
        attempts += 1
        if refuses { return false }
        delivered += 1
        return true
    }
}

/// The reports the Library raised, each already handed to the real reporter (the App's `Task { await reporter.report }`).
@MainActor
private final class TaskBag { var tasks: [Task<Void, Never>] = [] }

@MainActor
@Suite struct Oc0012RefusedPasteEndToEndTests {
    private static let catalogueText = "Couldn't paste into that app. The item is on your clipboard; press ⌘V."
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    /// OC-0012. given Accessibility granted and the target refusing the ⌘V, when Return pastes an item, then the HUD
    /// shows the LIB-OS-001 text once, the item's text is on the general pasteboard (written once), the reporter
    /// recorded exactly LIB-OS-001, nothing fatal was presented, and the Library still pastes the next time.
    /// Red if: the pasteboard write is skipped or undone on failure, the post failure is not reported (or is reported as
    /// another code or a Fatal), the HUD is not drawn for a user-initiated error, or the failure leaves the paste path dead.
    @Test("OC-0012 a refused ⌘V shows the LIB-OS-001 HUD, leaves the item on the pasteboard and the app still pastes")
    func refusedPasteEndToEnd() async throws {
        // given: a real database with one text item, the shipping PasteService over a pasteboard fake and a refusing target
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let tag = UUID().uuidString.lowercased()
        let item = try await lib.add(.text, key: "refused", text: "refused-\(tag)", secondsAgo: 5).itemId
        let pasteboard = ContractPasteboard()
        let keys = RefusingKeys()
        let host = GapHost()
        let presenter = HUDPresenter()
        let reporter = ErrorReporter(presenter: presenter)
        let reporting = TaskBag()
        let service = PasteService(
            store: lib.database, pasteboard: pasteboard, files: LocalFileSystem(), frontmost: GapFrontmost(target),
            accessibility: ContractTrust(true), keys: keys, clock: ContractClock(), ownWrites: OwnWriteLedger())
        let model = LibraryViewModel(
            source: lib.database, paster: service, host: host, preferences: FakePreferences(),
            effects: LibraryEffects(
                report: { error in reporting.tasks.append(Task { await reporter.report(error, origin: .userInitiated) }) },
                external: { _, _ in }, isAccessibilityTrusted: { true }))
        host.show()
        await model.open(target: target)

        // when: Return, and the reporter drains
        model.handle(LibraryKeyStroke(.returnKey, []))
        await model.pasteTask?.value
        await model.settled()
        for task in reporting.tasks { await task.value }

        // then: the HUD is the catalogue text, once, and nothing else was drawn
        #expect(presenter.huds == [Self.catalogueText])
        #expect(presenter.notices.isEmpty)
        #expect(presenter.fatals.isEmpty)
        #expect(await reporter.recentErrors().map(\.code.rawValue) == ["LIB-OS-001"])
        // and: the item is on the general pasteboard, written exactly once, with the item's own text; the ⌘V was tried once
        #expect(pasteboard.written.count == 1)
        #expect(pasteboard.lastText == "refused-\(tag)")
        #expect(keys.attempts == 1)
        #expect(keys.delivered == 0)
        // and: the process stayed alive and usable: the same Return now pastes, with no second HUD and no new error
        keys.refuses = false
        host.show()
        await model.open(target: target)
        model.handle(LibraryKeyStroke(.returnKey, []))
        await model.pasteTask?.value
        await model.settled()
        for task in reporting.tasks { await task.value }
        #expect(keys.delivered == 1)
        #expect(presenter.huds.count == 1)
        #expect(await reporter.recentErrors().count == 1)
        #expect(try await lib.allRows().first { $0.id == item }?.pasteCount == 2)
    }
}
