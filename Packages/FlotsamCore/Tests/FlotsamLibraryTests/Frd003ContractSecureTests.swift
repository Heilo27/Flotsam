import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-504 (Worf), FR-003-23 / AC-003-19, oracle entries OC-3106 to OC-3118 in .claude/oracle/frd-003-contract.json,
// written blind from the FRD text. The collaborators are the shipping ones (a real FlotsamDatabase, PasteService,
// SecureClipAccess, LibraryViewModel, LibraryRowPresentation, LibraryContextMenu); only the Keychain vault, the owner
// check, the pasteboard and the key-event poster are fakes, so no test touches the Keychain or LocalAuthentication.
// Expected values are literals from the FRD and the error catalogue, never production symbols.

// MARK: Fakes

/// Every vault or authenticator call, in order, so "decrypt only after the owner answered" is an ordering fact.
final class SecureContractLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ event: String) { lock.withLock { storage.append(event) } }
    var events: [String] { lock.withLock { storage } }
}

/// A vault with a scripted key. `open` logs and counts every decrypt it is asked for.
final class SecureContractVault: SecureClipVaulting, @unchecked Sendable {
    private let lock = NSLock()
    private let log: SecureContractLog
    private var secrets: [Data: String] = [:]
    private var _keyAvailable = true
    private var _opens = 0

    init(log: SecureContractLog) { self.log = log }

    var isKeyAvailable: Bool {
        get { lock.withLock { _keyAvailable } }
        set { lock.withLock { _keyAvailable = newValue } }
    }
    var opens: Int { lock.withLock { _opens } }

    func seal(_ text: String) -> FlotsamResult<SealedSecret> {
        let ciphertext = Data(text.utf8.reversed()) + Data([0xAE, 0x5E])
        lock.withLock { secrets[ciphertext] = text }
        return .success(SealedSecret(ciphertext: ciphertext, fingerprint: "fp-" + ciphertext.map { String($0, radix: 16) }.joined()))
    }

    func open(_ ciphertext: Data) -> FlotsamResult<String> {
        log.add("open")
        lock.withLock { _opens += 1 }
        guard isKeyAvailable, let text = lock.withLock({ secrets[ciphertext] }) else {
            return .failure(FlotsamError(.libDat002, "fake vault cannot open"))
        }
        return .success(text)
    }
}

/// An owner check that answers from a script (the last answer repeats) and records every request.
final class SecureContractAuthenticator: UserAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private let log: SecureContractLog
    private var answers: [FlotsamResult<Void>]
    private var _requests = 0

    init(log: SecureContractLog, answers: [FlotsamResult<Void>]) {
        self.log = log
        self.answers = answers
    }

    var requests: Int { lock.withLock { _requests } }
    func authenticate(reason: String) async -> FlotsamResult<Void> {
        log.add("auth")
        return lock.withLock {
            _requests += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    static var cancelled: FlotsamResult<Void> { .failure(FlotsamError(.libOs002, "cancelled by the owner")) }
    static var succeeds: FlotsamResult<Void> { .success(()) }
}

// MARK: Rig

@MainActor
struct SecureContractRig {
    static let secret = "hunter2-secret"
    static let plainTitle = "plain-text"

    let root: URL
    let epoch = Date()
    let log = SecureContractLog()
    let vault: SecureContractVault
    let authenticator: SecureContractAuthenticator
    let database: FlotsamDatabase
    let ingest: IngestActor
    let pasteboard = ContractPasteboard()
    let keys = ContractKeys()
    let host = FakeHost()
    let reported = Harness.Reported()
    let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)
    let model: LibraryViewModel

    /// The panel over a real database that holds the fake vault, with the pasteboard already holding "before".
    init(answers: [FlotsamResult<Void>] = [SecureContractAuthenticator.succeeds]) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-504-\(UUID().uuidString)")
        vault = SecureContractVault(log: log)
        authenticator = SecureContractAuthenticator(log: log, answers: answers)
        database = try await FlotsamDatabase.open(folder: root, secureVault: vault).get()
        ingest = IngestActor(database: database, settings: SettingsStore(store: ContractMemoryKV()))
        _ = pasteboard.write([PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("before".utf8))])
        let service = PasteService(
            store: database, pasteboard: pasteboard, files: LocalFileSystem(), frontmost: ContractFrontmost(target),
            accessibility: ContractTrust(true), keys: keys, clock: ContractClock(), ownWrites: OwnWriteLedger(),
            secureAccess: SecureClipAccess(vault: vault, authenticator: authenticator))
        let reported = reported
        model = LibraryViewModel(
            source: database, paster: service, host: host, preferences: FakePreferences(),
            effects: LibraryEffects(
                report: { reported.errors.append($0) }, external: { reported.external.append(($0, $1)) },
                isAccessibilityTrusted: { true }))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Seals and ingests a concealed copy from the Passwords app.
    @discardableResult
    func addSecure(_ secret: String = SecureContractRig.secret, secondsAgo: Double = 0) async throws -> UUID {
        let sealed = try vault.seal(secret).get()
        let candidate = IngestCandidate(
            secure: sealed, source: SourceApp(bundleId: "com.apple.Passwords", name: "Passwords"), origin: .pasteboard,
            occurredAt: epoch.addingTimeInterval(-secondsAgo))
        return try await ingest.ingest(candidate).get().itemId
    }

    @discardableResult
    func addPlain(_ text: String = SecureContractRig.plainTitle, secondsAgo: Double = 5) async throws -> UUID {
        let candidate = IngestCandidate(
            kind: .text, contentKey: "plain:" + text, plainText: text, representations: [], members: [],
            source: SourceApp(bundleId: "com.example.notes", name: "Notes"), origin: .pasteboard,
            occurredAt: epoch.addingTimeInterval(-secondsAgo), originalPath: nil)
        return try await ingest.ingest(candidate).get().itemId
    }

    /// The panel opening: rows are read through the shipping query layer.
    func open() async { await model.open(target: target) }

    func select(_ id: UUID) {
        model.select(id: id)
    }

    /// A key, then the paste it started (if any). Returns whether the Library handled the key.
    @discardableResult
    func press(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) async -> Bool {
        let handled = model.handle(LibraryKeyStroke(input, modifiers))
        await model.pasteTask?.value
        await model.settled()
        return handled
    }

    /// The command behind a context-menu line, found by its visible title.
    func menuCommand(_ title: String, secure: Bool) -> LibraryCommand? {
        for entry in LibraryContextMenu.entries(kind: .text, pinUnpins: false, singleTarget: true, isSecure: secure) {
            if case .item(let key, let command, _) = entry, LibraryText.string(key) == title { return command }
        }
        return nil
    }

    /// Runs a command the way a menu click or double-click does, then waits for the paste it started.
    func run(_ command: LibraryCommand) async {
        model.perform(command)
        await model.pasteTask?.value
        await model.settled()
    }

    func presentations() -> [LibraryRowPresentation] {
        model.visibleRows.enumerated().map { LibraryRowPresentation(row: $1, position: $0, now: epoch) }
    }

    /// Times pasted, read fresh from the database.
    func pasteCount(_ id: UUID) async throws -> Int {
        try await database.items(matching: LibraryQuery(page: 0)).get().rows.first { $0.id == id }?.pasteCount ?? -1
    }

    /// The text of the last pasteboard write, or nil.
    var lastText: String? { pasteboard.lastText }
    /// The type identifiers of the last pasteboard write, sorted.
    var lastTypes: [String] { (pasteboard.written.last ?? []).map(\.uti).sorted() }
}

// MARK: Suite

@MainActor
@Suite struct Frd003ContractSecureTests {
    private static let libOs002Text = "Not copied. Confirm it's you to copy a secure item."
    private static let libDat002Text = "This secure item can't be unlocked on this Mac."
    private static let revealedTypes = [
        "com.flotsam.own-write", "org.nspasteboard.AutoGeneratedType", "org.nspasteboard.ConcealedType",
        "public.utf8-plain-text",
    ]

    private func messages(_ rig: SecureContractRig) -> [String] { rig.reported.errors.map { FlotsamStrings.message(for: $0) } }
    private func codes(_ rig: SecureContractRig) -> [ErrorCode] { rig.reported.errors.map(\.code) }

    /// Asserts nothing was written and nothing pasted since the "before" seed.
    private func expectUntouched(_ rig: SecureContractRig, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(rig.pasteboard.changeCount == 1, sourceLocation: sourceLocation)
        #expect(rig.pasteboard.written.count == 1, sourceLocation: sourceLocation)
        #expect(rig.lastText == "before", sourceLocation: sourceLocation)
        #expect(rig.keys.posts == 0, sourceLocation: sourceLocation)
    }

    // MARK: OC-3106, OC-3107 the row

    // Red if the row's primary text reads `primaryLine` or the secret instead of the mask, if the secure flag is dropped
    // from the presentation, or if the secret leaks into the source line or accessibility label.
    @Test("OC-3106 AC-003-19 FR-003-23: a secure row shows the mask and the source app, never the secret; the plain row is unaffected")
    func secureRowShowsMaskAndSource() async throws {
        // given a secure item (secret 'hunter2-secret', source 'Passwords') and a plain text item
        let rig = try await SecureContractRig()
        let secureId = try await rig.addSecure(secondsAgo: 0)
        let plainId = try await rig.addPlain("plain-text", secondsAgo: 5)

        // when the Library is shown
        await rig.open()

        // then two rows: the secure one masked with its source, the plain one as it was
        let rows = rig.presentations()
        #expect(rows.count == 2)
        let secure = try #require(rows.first { $0.id == secureId })
        #expect(secure.isSecure)
        #expect(secure.primaryText == "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
        #expect(secure.secondaryText.contains("Passwords"))
        #expect(secure.unavailableBadge == nil)
        for text in [secure.primaryText, secure.secondaryText, secure.accessibilityLabel] {
            #expect(!text.contains("hunter2"))
            #expect(!text.contains("secret"))
        }
        let plain = try #require(rows.first { $0.id == plainId })
        #expect(!plain.isSecure)
        #expect(plain.primaryText == "plain-text")
        #expect(plain.unavailableBadge == nil)
        // the loaded row model (what the query layer returns, and search and sort read) is already the mask, not the text
        let loaded = try #require(rig.model.visibleRows.first { $0.id == secureId })
        #expect(loaded.primaryLine == "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
        #expect(!loaded.primaryLine.contains("hunter2"))
        rig.cleanUp()
    }

    // Red if the unavailable marking is dropped (no badge), if the badge replaces the mask, or if opening the Library
    // with a missing key reports an error or prompts the owner.
    @Test("OC-3107 AC-003-19 FR-003-23: with the key unreadable the row keeps the mask and source and adds the Unavailable badge")
    func unavailableRowKeepsMaskAndAddsBadge() async throws {
        // given a secure item whose Keychain key cannot be read
        let rig = try await SecureContractRig()
        let secureId = try await rig.addSecure()
        try await rig.addPlain()
        rig.vault.isKeyAvailable = false

        // when the Library is shown
        await rig.open()

        // then the mask, source and an Unavailable badge show; no error, no prompt, no decrypt
        let secure = try #require(rig.presentations().first { $0.id == secureId })
        #expect(secure.primaryText == "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
        #expect(secure.isSecure)
        #expect(secure.secondaryText.contains("Passwords"))
        #expect(secure.unavailableBadge == "Unavailable")
        #expect(!secure.accessibilityLabel.contains("hunter2"))
        let plain = try #require(rig.presentations().first { !$0.isSecure })
        #expect(plain.unavailableBadge == nil)
        #expect(rig.reported.errors.isEmpty)
        #expect(rig.authenticator.requests == 0)
        #expect(rig.vault.opens == 0)
        rig.cleanUp()
    }

    // MARK: OC-3108, OC-3109 cancel and failure copy nothing

    // Red if the check's failure is ignored (the secret is written anyway), if the error is not reported, or if it is
    // reported twice. The cancelled keys are Return and Shift-Return; Command-C is pinned separately below.
    @Test("OC-3108 AC-003-19 FR-003-23: a cancelled check copies nothing for Return and Shift-Return and reports LIB-OS-002 once each")
    func cancelCopiesNothing() async throws {
        // given a secure item, a readable key and an authenticator that is cancelled
        let rig = try await SecureContractRig(answers: [SecureContractAuthenticator.cancelled])
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)

        // when Return is used
        await rig.press(.returnKey)

        // then one LIB-OS-002 with the catalogue text; nothing written, pasted or counted
        #expect(codes(rig) == [.libOs002])
        #expect(messages(rig) == [Self.libOs002Text])
        expectUntouched(rig)
        #expect(try await rig.pasteCount(id) == 0)

        // when Shift-Return is used
        await rig.press(.returnKey, .shift)

        // then exactly one more error, and still nothing copied
        #expect(codes(rig) == [.libOs002, .libOs002])
        expectUntouched(rig)
        #expect(rig.authenticator.requests == 2)
        #expect(try await rig.pasteCount(id) == 0)
        rig.cleanUp()
    }

    // Red if only a user cancel (and not an authentication failure) is treated as a refusal.
    @Test("OC-3109 AC-003-19 FR-003-23: a failed (not cancelled) check is reported exactly as a cancel and records nothing")
    func failedCheckIsReportedLikeCancel() async throws {
        // given a secure item and an authenticator that fails
        let failure: FlotsamResult<Void> = .failure(FlotsamError(.libOs002, "the owner was not recognised"))
        let rig = try await SecureContractRig(answers: [failure])
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)

        // when Return is used
        await rig.press(.returnKey)

        // then LIB-OS-002 exactly as for a cancel, nothing written, pasted or recorded
        #expect(codes(rig) == [.libOs002])
        #expect(messages(rig) == [Self.libOs002Text])
        expectUntouched(rig)
        #expect(try await rig.pasteCount(id) == 0)
        #expect(rig.vault.opens == 0)
        rig.cleanUp()
    }

    // MARK: OC-3110 key missing never prompts

    // Red if the key check moves after the prompt (the owner is asked for an item that cannot open), or if the missing
    // key reports LIB-OS-002 instead of LIB-DAT-002.
    @Test("OC-3110 AC-003-19 FR-003-23: a missing key reports LIB-DAT-002 for Return and Shift-Return and never asks the owner")
    func missingKeyNeverPrompts() async throws {
        // given a secure item whose key is gone and an authenticator that records requests
        let rig = try await SecureContractRig()
        let id = try await rig.addSecure()
        rig.vault.isKeyAvailable = false
        await rig.open()
        rig.select(id)

        // when Return, then Shift-Return are used
        await rig.press(.returnKey)
        await rig.press(.returnKey, .shift)

        // then LIB-DAT-002 each time, zero prompts, nothing written or pasted
        #expect(codes(rig) == [.libDat002, .libDat002])
        #expect(messages(rig) == [Self.libDat002Text, Self.libDat002Text])
        #expect(rig.authenticator.requests == 0)
        expectUntouched(rig)
        #expect(try await rig.pasteCount(id) == 0)
        rig.cleanUp()
    }

    // MARK: OC-3111, OC-3112 the re-copy

    // Red if the secret is written without the Concealed or own-write markers, with an extra representation, if the
    // pasteboard is not written at all, or if the vault is read before the owner answered.
    @Test("OC-3111 AC-003-19 FR-003-23: an authorised re-copy writes the secret as plain text with exactly the concealed and own-write markers, after the check")
    func authorisedRecopyWritesConcealedText() async throws {
        // given a secure item, a readable key, a succeeding authenticator; the pasteboard holds 'before'
        let rig = try await SecureContractRig()
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)
        #expect(rig.lastText == "before")

        // when Return is used
        await rig.press(.returnKey)

        // then the secret is on the pasteboard with exactly the four types, one write, decrypt after the check
        #expect(rig.lastText == "hunter2-secret")
        #expect(rig.lastTypes == [
            "com.flotsam.own-write", "org.nspasteboard.AutoGeneratedType", "org.nspasteboard.ConcealedType",
            "public.utf8-plain-text",
        ])
        #expect(rig.pasteboard.written.count == 2)
        #expect(rig.pasteboard.changeCount == 2)
        #expect(rig.log.events == ["auth", "open"])
        #expect(rig.reported.errors.isEmpty)
        #expect(try await rig.pasteCount(id) == 1)
        rig.cleanUp()
    }

    // Red if a mode (plain text, copy only) writes the secret without ConcealedType or with a different type list.
    @Test("OC-3112 AC-003-19 FR-003-23: Return, Option-Return and Shift-Return all re-copy as plain text with the same markers")
    func recopyIsTheSameInEveryMode() async throws {
        // given a secure item and a succeeding authenticator
        let rig = try await SecureContractRig()
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)

        // when each of the three modes is used in turn
        await rig.press(.returnKey)
        let formatted = rig.lastTypes
        await rig.press(.returnKey, .option)
        let plain = rig.lastTypes
        await rig.press(.returnKey, .shift)
        let copyOnly = rig.lastTypes

        // then three writes of the same literal type list, each carrying the secret
        #expect(rig.pasteboard.written.count == 4)
        #expect(formatted == Self.revealedTypes)
        #expect(plain == Self.revealedTypes)
        #expect(copyOnly == Self.revealedTypes)
        #expect(rig.pasteboard.written.dropFirst().map { $0.first { $0.uti == "public.utf8-plain-text" }.map { String(decoding: $0.data, as: UTF8.self) } } == [
            "hunter2-secret", "hunter2-secret", "hunter2-secret",
        ])
        #expect(rig.reported.errors.isEmpty)
        rig.cleanUp()
    }

    // MARK: OC-3113 (Library half: what the re-copy leaves for capture and {clipboard}; the capture half is in FlotsamCaptureTests)

    // Red if the re-copy loses ConcealedType (clipboard managers and {clipboard} would see the password) or the own-write
    // marker (Flotsam would capture its own write).
    @Test("OC-3113 AC-003-19 FR-005-16: after a re-copy the pasteboard reads as concealed, so {clipboard} is empty; an ordinary copy is held with its text")
    func recopyReadsEmptyForClipboardVariable() async throws {
        // given a secure item and a plain item, both re-copied through Return
        let rig = try await SecureContractRig()
        let secureId = try await rig.addSecure()
        let plainId = try await rig.addPlain("plain-text", secondsAgo: 5)
        await rig.open()
        let preserver = ClipboardPreserver(pasteboard: rig.pasteboard, ownWrites: OwnWriteLedger(), clock: ContractClock())

        // when the secure item is re-copied and {clipboard} is read
        rig.select(secureId)
        await rig.press(.returnKey)
        let afterSecure = preserver.capture()

        // then it is concealed with empty text, and the own-write marker is on the board
        #expect(afterSecure.disposition == .concealed)
        #expect(afterSecure.plainText == "")
        #expect(rig.pasteboard.currentTypeIdentifiers().contains("com.flotsam.own-write"))

        // when the plain item is re-copied and {clipboard} is read (control)
        rig.select(plainId)
        await rig.press(.returnKey)
        let afterPlain = preserver.capture()

        // then it is held with its text, so the empty result above is the concealed marker and not a dead reader
        #expect(afterPlain.disposition == .held)
        #expect(afterPlain.plainText == "plain-text")
        rig.cleanUp()
    }

    // MARK: OC-3114, OC-3115 no cache, no memory of a cancel

    // Red if an approval is cached or given a grace period (the second Return would not ask again).
    @Test("OC-3114 AC-003-19 FR-003-23: every authorised action asks the owner again (Return twice asks twice)")
    func everyActionAsksAgain() async throws {
        // given a secure item and a succeeding authenticator
        let rig = try await SecureContractRig()
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)

        // when Return is used twice in a row
        await rig.press(.returnKey)
        await rig.press(.returnKey)

        // then the owner was asked twice, each time before the decrypt
        #expect(rig.authenticator.requests == 2)
        #expect(rig.log.events == ["auth", "open", "auth", "open"])
        #expect(rig.pasteboard.written.count == 3)
        rig.cleanUp()
    }

    // Red if a cancel is remembered (the retry would not prompt, or would stay refused), or if a refused first attempt
    // left something on the pasteboard.
    @Test("OC-3115 AC-003-19 FR-003-23: a cancel is not remembered: the retry prompts again and succeeds")
    func cancelIsNotRemembered() async throws {
        // given an authenticator cancelled the first time and succeeding the second
        let rig = try await SecureContractRig(answers: [SecureContractAuthenticator.cancelled, SecureContractAuthenticator.succeeds])
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)

        // when Return is used, cancelled, and used again
        await rig.press(.returnKey)

        // then the first use reports LIB-OS-002 and writes nothing
        #expect(codes(rig) == [.libOs002])
        expectUntouched(rig)

        await rig.press(.returnKey)

        // then the second use prompts again and puts the secret on the pasteboard, with no new error
        #expect(rig.authenticator.requests == 2)
        #expect(rig.lastText == "hunter2-secret")
        #expect(rig.lastTypes == Self.revealedTypes)
        #expect(codes(rig) == [.libOs002])
        rig.cleanUp()
    }

    // MARK: OC-3116 every copy route is gated

    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case optionReturn, doubleClick, menuPaste, menuPastePlain, menuCopy
        var testDescription: String { rawValue }
    }

    private func use(_ route: Route, on rig: SecureContractRig) async throws {
        switch route {
        case .optionReturn: await rig.press(.returnKey, .option)
        case .doubleClick:
            // The row's double-click calls exactly `model.perform(.paste(.paste))` (App/Flotsam/Library/LibraryRows.swift:70).
            await rig.run(.paste(.paste))
        case .menuPaste: await rig.run(try #require(rig.menuCommand("Paste", secure: true)))
        case .menuPastePlain: await rig.run(try #require(rig.menuCommand("Paste as Plain Text", secure: true)))
        case .menuCopy: await rig.run(try #require(rig.menuCommand("Copy", secure: true)))
        }
    }

    // Red if any one route reaches the pasteboard without the owner check (that route's cancelled attempt would write),
    // or if the route stops writing the secret as concealed plain text once the check passes.
    @Test("OC-3116 AC-003-19 FR-003-23: every Library route that puts a secure item on the clipboard asks first", arguments: Route.allCases)
    func everyRouteIsGated(route: Route) async throws {
        // given a secure item and an authenticator cancelled the first time and succeeding the second
        let rig = try await SecureContractRig(answers: [SecureContractAuthenticator.cancelled, SecureContractAuthenticator.succeeds])
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)

        // when the route is used and the owner cancels
        try await use(route, on: rig)

        // then the owner was asked, nothing was written, and LIB-OS-002 was reported once
        #expect(rig.log.events == ["auth"])
        #expect(codes(rig) == [.libOs002])
        expectUntouched(rig)

        // when the route is used again and the owner confirms
        try await use(route, on: rig)

        // then the secret is on the pasteboard as plain text with the concealed markers
        #expect(rig.log.events == ["auth", "auth", "open"])
        #expect(rig.lastText == "hunter2-secret")
        #expect(rig.lastTypes == Self.revealedTypes)
        #expect(codes(rig) == [.libOs002])
        rig.cleanUp()
    }

    // MARK: OC-3117 control: ordinary items are never gated

    // Red if the gate is applied to every item (a plain copy would prompt) or if plain text were ever marked concealed.
    @Test("OC-3117 AC-003-19 FR-003-23: a plain text item is copied with no prompt and no ConcealedType")
    func plainItemIsNotGated() async throws {
        // given a plain text item and a recording authenticator
        let rig = try await SecureContractRig()
        let id = try await rig.addPlain("plain-text", secondsAgo: 0)
        await rig.open()
        rig.select(id)

        // when Return, then Copy in the context menu are used
        await rig.press(.returnKey)
        let afterReturn = rig.lastText
        let typesAfterReturn = rig.lastTypes
        await rig.run(try #require(rig.menuCommand("Copy", secure: false)))

        // then no prompt, the text on the pasteboard, no ConcealedType, no error
        #expect(rig.authenticator.requests == 0)
        #expect(afterReturn == "plain-text")
        #expect(rig.lastText == "plain-text")
        #expect(!typesAfterReturn.contains("org.nspasteboard.ConcealedType"))
        #expect(!rig.lastTypes.contains("org.nspasteboard.ConcealedType"))
        #expect(rig.pasteboard.written.count == 3)
        #expect(rig.reported.errors.isEmpty)
        rig.cleanUp()
    }

    // MARK: OC-3118 decrypt only after the check

    // Red if the vault is asked to decrypt before or without a successful check, or if the counter is dead (the control
    // run proves one authorised copy does decrypt exactly once).
    @Test("OC-3118 AC-003-19 FR-003-23: the vault is never asked to decrypt after a cancel or with the key missing; one decrypt after a success")
    func vaultOpensOnlyAfterSuccess() async throws {
        // cancelled: no decrypt
        let cancelled = try await SecureContractRig(answers: [SecureContractAuthenticator.cancelled])
        let cancelledId = try await cancelled.addSecure()
        await cancelled.open()
        cancelled.select(cancelledId)
        await cancelled.press(.returnKey)
        await cancelled.press(.returnKey, .shift)
        #expect(cancelled.authenticator.requests == 2)
        #expect(cancelled.vault.opens == 0)
        #expect(cancelled.log.events == ["auth", "auth"])
        cancelled.cleanUp()

        // key missing: no decrypt
        let missing = try await SecureContractRig()
        let missingId = try await missing.addSecure()
        missing.vault.isKeyAvailable = false
        await missing.open()
        missing.select(missingId)
        await missing.press(.returnKey)
        #expect(missing.vault.opens == 0)
        #expect(missing.log.events == [])
        missing.cleanUp()

        // control: a success decrypts exactly once
        let ok = try await SecureContractRig()
        let okId = try await ok.addSecure()
        await ok.open()
        ok.select(okId)
        await ok.press(.returnKey)
        #expect(ok.vault.opens == 1)
        #expect(ok.log.events == ["auth", "open"])
        ok.cleanUp()
    }

    // MARK: Command-C (FR-003-23 / AC-003-19 name it; FR-003-08 does not list it)

    // The FRD text of FR-003-23 and AC-003-19 says Command-C on a secure row asks the owner before anything is copied.
    // The Library key map has no Command-C row (LibraryKeyMap.swift table, no `.character("c")` entry) and
    // FR-003-08 does not list it, so the key is unhandled and falls through to the search field. [Spec Drift] between
    // FR-003-08 and FR-003-23/AC-003-19, surfaced to Ryan. These tests state the AC as written and are expected to
    // fail today; when Command-C is wired (or the FRD drops it) `withKnownIssue` reports "did not fail" and this block
    // is to be removed or rewritten with the ruling.
    private func cmdC(on rig: SecureContractRig) async -> Bool { await rig.press(.character("c"), .command) }

    @Test("OC-3108 AC-003-19 [Spec Drift]: Command-C on a cancelled secure row is gated and copies nothing")
    func commandCCancelled() async throws {
        let rig = try await SecureContractRig(answers: [SecureContractAuthenticator.cancelled])
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)
        await withKnownIssue("FR-003-23/AC-003-19 name Command-C; the Library has no Command-C binding (FR-003-08 omits it)") {
            let handled = await cmdC(on: rig)
            #expect(handled)
            #expect(rig.authenticator.requests == 1)
            #expect(codes(rig) == [.libOs002])
        }
        // not part of the known issue: whatever Command-C does today, it never writes the secret
        #expect(rig.lastText != "hunter2-secret")
        rig.cleanUp()
    }

    @Test("OC-3110 AC-003-19 [Spec Drift]: Command-C on a secure row with a missing key reports LIB-DAT-002 without a prompt")
    func commandCMissingKey() async throws {
        let rig = try await SecureContractRig()
        let id = try await rig.addSecure()
        rig.vault.isKeyAvailable = false
        await rig.open()
        rig.select(id)
        await withKnownIssue("FR-003-23/AC-003-19 name Command-C; the Library has no Command-C binding (FR-003-08 omits it)") {
            let handled = await cmdC(on: rig)
            #expect(handled)
            #expect(codes(rig) == [.libDat002])
        }
        #expect(rig.authenticator.requests == 0)
        rig.cleanUp()
    }

    @Test("OC-3114 AC-003-19 [Spec Drift]: Return twice then Command-C asks the owner three times")
    func commandCAsksAgain() async throws {
        let rig = try await SecureContractRig()
        let id = try await rig.addSecure()
        await rig.open()
        rig.select(id)
        await rig.press(.returnKey)
        await rig.press(.returnKey)
        await withKnownIssue("FR-003-23/AC-003-19 name Command-C; the Library has no Command-C binding (FR-003-08 omits it)") {
            await cmdC(on: rig)
            #expect(rig.authenticator.requests == 3)
        }
        rig.cleanUp()
    }

    @Test("OC-3117 AC-003-19 [Spec Drift]: Command-C on a plain text item copies its text with no prompt")
    func commandCPlain() async throws {
        let rig = try await SecureContractRig()
        let id = try await rig.addPlain("plain-text", secondsAgo: 0)
        await rig.open()
        rig.select(id)
        await withKnownIssue("FR-003-23/AC-003-19 name Command-C; the Library has no Command-C binding (FR-003-08 omits it)") {
            let handled = await cmdC(on: rig)
            #expect(handled)
            #expect(rig.lastText == "plain-text")
        }
        #expect(rig.authenticator.requests == 0)
        rig.cleanUp()
    }
}
