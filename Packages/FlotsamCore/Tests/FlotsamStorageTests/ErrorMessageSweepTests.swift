import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-398 sweep: every catalogue code, rendered with the context its real raise sites supply, must not fall back to
// SYS-INT-001. The codes that carry a placeholder are raised through the real code paths (ingest limits, organise
// commands); the rest are the contexts the other modules' raise sites pass, listed with their site so a change there
// is a change here. Expected outcome is "not the fallback", read from the catalogue, never from the code under test.

private let fallback = "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About."

private let fakeClassifiers = ItemClassifiers(
    editedText: { text in ItemClassification(kind: .text, contentKey: "edit:" + text) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

private func candidate(
    kind: ItemKind, origin: CaptureOrigin, text: String? = nil, image: Data? = nil, members: Int = 0, rtf: Data? = nil
) -> IngestCandidate {
    var representations: [PasteboardRepresentation] = []
    if let image { representations.append(PasteboardRepresentation(uti: "public.png", data: image)) }
    if let rtf { representations.append(PasteboardRepresentation(uti: "public.rtf", data: rtf)) }
    return IngestCandidate(
        kind: kind, contentKey: "k", plainText: text, representations: representations,
        members: (0..<members).map { IngestMember(path: "/tmp/f\($0)", bookmark: nil, isDirectory: false) },
        origin: origin, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
}

/// Errors raised by the real ingest-limit code: every skip code by origin, plus the two warnings.
private func ingestLimitRaises() -> [FlotsamError] {
    let overText = String(repeating: "a", count: IngestLimits.maxTextBytes + 1)
    let overImage = Data(count: IngestLimits.maxImageBytes + 1)
    let overRich = Data(count: IngestLimits.maxRichRepresentationBytes + 1)
    var raised: [FlotsamError] = []
    for origin in [CaptureOrigin.pasteboard, .shelfDrop, .screenshotFile] {
        if case .failure(let error) = IngestLimits.apply(to: candidate(kind: .text, origin: origin, text: overText)) { raised.append(error) }
        if case .failure(let error) = IngestLimits.apply(to: candidate(kind: .image, origin: origin, image: overImage)) { raised.append(error) }
    }
    if case .success(let limited) = IngestLimits.apply(
        to: candidate(kind: .richText, origin: .pasteboard, text: "x", rtf: overRich)) { raised += limited.warnings }
    if case .success(let limited) = IngestLimits.apply(
        to: candidate(kind: .bundle, origin: .pasteboard, members: IngestLimits.maxBundleMembers + 1)) { raised += limited.warnings }
    return raised
}

/// Errors raised by the real organise commands that state a limit.
private func organiseRaises() async throws -> [FlotsamError] {
    let store = try await Store.make()
    defer { store.cleanUp() }
    try await store.insert([Spec(n: 1), Spec(n: 2)])
    var raised: [FlotsamError] = []
    func collect<T>(_ result: FlotsamResult<T>) { if case .failure(let error) = result { raised.append(error) } }

    collect(await store.database.editText(
        id: Store.id(2), to: String(repeating: "a", count: IngestLimits.maxTextBytes + 1), classifiers: fakeClassifiers))
    collect(await store.database.setNote(String(repeating: "n", count: IngestLimits.maxNoteCharacters + 1), for: Store.id(1)))
    for n in 1...100 { _ = try await store.database.createTag(name: "tag \(n)").get() }
    collect(await store.database.createTag(name: "one more"))
    return raised
}

/// The context the raise sites outside Storage's limit and organise paths pass (file named per entry). Inputs only.
private let itemId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let otherSites: [FlotsamError] = [
    FlotsamError(.capLim003, "x", context: [.count: .int(500)]),                           // FlotsamPayload/CaptureClassifier.swift
    FlotsamError(.libDat001, "x", context: [.itemId: .id(itemId)]),                        // FlotsamPaste/PastePayload.swift
    FlotsamError(.setPrm001, "x", context: [.itemId: .id(itemId)]),                        // FlotsamLibrary/LibraryViewModel.swift
    FlotsamError(.capPrm001, "x", context: [.permission: .permission(.pasteboard)]),       // FlotsamCapture/ClipboardCapture.swift
    FlotsamError(.sysInt001, "x", context: [.itemId: .id(itemId)]),                        // FlotsamStorage/Organize/Ungroup.swift
    FlotsamError(.orgVal003, "x", context: [.itemId: .id(itemId)]),                        // FlotsamStorage/Organize/EditText.swift
    FlotsamError(.orgLim001, "x", context: [.itemId: .id(itemId)]),                        // FlotsamStorage/Organize/Tags.swift
    FlotsamError(.stoIo001, "x", context: [.byteSize: .bytes(4_096)]),                     // Limits/DiskGuard.swift, Blobs/BlobStore.swift
    FlotsamError(.stoLim002, "x", context: [.byteSize: .bytes(419_430_400)]),              // Limits/DiskGuard.swift
    FlotsamError(.stoIo003, "x", context: [.itemId: .id(itemId)]),                         // Reliability/Reconcile.swift
    FlotsamError(.libIo001, "x", context: [.itemId: .id(itemId)]),                         // Query/ItemContent.swift
]

@Suite struct ErrorMessageSweepTests {
    /// Warning and Error codes only: Fatal renders in the alert and Info has no user message (FR-000-04), but Fatal
    /// codes are still swept because FatalAlert renders them through the same call.
    private var userFacingCodes: [ErrorCode] {
        ErrorCode.allCases.filter { $0.severity != .info && FlotsamStrings.text(forKey: $0.catalogueKey) != nil }
    }

    @Test("every user-facing catalogue code renders its own catalogue text, never SYS-INT-001, from each real raise context")
    func noCodeFallsBack() async throws {
        let raised = ingestLimitRaises() + (try await organiseRaises()) + otherSites
        var checked = 0
        for code in userFacingCodes where code != .sysInt001 {
            // A code no site raises with context is still rendered bare: it must have a placeholder-free template.
            let errors = raised.filter { $0.code == code }
            for error in errors.isEmpty ? [FlotsamError(code, "bare")] : errors {
                #expect(FlotsamStrings.message(for: error) != fallback, "\(code.rawValue) with context \(error.context)")
                checked += 1
            }
        }
        #expect(checked >= userFacingCodes.count - 1)
    }

    @Test("every code whose catalogue text has a placeholder is exercised by a real raise, so the sweep cannot go vacuous")
    func placeholderCodesAreRaisedForReal() async throws {
        let real = Set((ingestLimitRaises() + (try await organiseRaises())).map(\.code))
        let withPlaceholder = userFacingCodes.filter { !$0.messageArgumentKinds.isEmpty }
        #expect(!withPlaceholder.isEmpty)
        for code in withPlaceholder where code != .capLim003 {   // CAP-LIM-003 is real-raised by IngestLimits too, asserted below
            #expect(real.contains(code), "\(code.rawValue) has a placeholder but no real raise in the sweep")
        }
        #expect(real.contains(.capLim003))
    }

    @Test("the real raises render the placeholder value: the size or the count appears in the text")
    func placeholderValuesAppear() async throws {
        let raised = ingestLimitRaises() + (try await organiseRaises())
        func message(_ code: ErrorCode) throws -> String {
            FlotsamStrings.message(for: try #require(raised.first { $0.code == code }))
        }
        #expect(try message(.capLim001).contains("MB"))
        #expect(try message(.sspLim001).contains("MB"))
        #expect(try message(.shfLim001).contains("MB"))
        #expect(try message(.orgLim003) == "That text is over the 10 MB limit. Shorten it and try again.")
        #expect(try message(.capLim003) == "A copy of 501 files was trimmed to the first 500.")
        #expect(try message(.orgVal002) == "Notes can be up to 2,000 characters.")
        #expect(try message(.orgLim002) == "You can have up to 100 tags.")
    }
}
