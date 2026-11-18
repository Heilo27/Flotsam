import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
import FlotsamStorage
@testable import FlotsamShelf

/// FRD-006 FR-006-12 to FR-006-14 and FRD-006 section 5 (BR-2, BR-4): what a drag is accepted for and what a dropped
/// pasteboard becomes. Pure: the only file-system question, "can this file be read", is injected. Real (empty) files
/// exist on disk because the classifier, as for clipboard capture, drops a path that is not there.
@Suite struct ShelfDropPlannerTests {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)
    private let finder = SourceApp(bundleId: "com.apple.finder", name: "Finder")

    private func text(_ string: String) -> PasteboardRepresentation {
        PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(string.utf8))
    }

    private func fileRep(_ url: URL) -> PasteboardRepresentation {
        PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data(url.absoluteString.utf8))
    }

    /// A scratch folder holding `names` as empty files, removed when `body` returns.
    private func withFiles<T>(_ names: [String], _ body: ([URL]) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-planner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try names.map { name -> URL in
            let url = root.appendingPathComponent(name)
            try Data().write(to: url)
            return url
        }
        return try body(urls)
    }

    private func plan(
        _ types: [String], _ reps: [PasteboardRepresentation], source: SourceApp? = nil,
        isReadable: (String) -> Bool = { _ in true }
    ) -> FlotsamResult<ShelfDropPlan> {
        ShelfDropPlanner.plan(types: types, representations: reps, source: source, occurredAt: when, isReadable: isReadable)
    }

    private func code(_ result: FlotsamResult<ShelfDropPlan>) -> ErrorCode? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    private func value(_ result: FlotsamResult<ShelfDropPlan>) -> ShelfDropPlan? {
        if case .success(let plan) = result { return plan }
        return nil
    }

    // MARK: Acceptance (FR-006-12, AC-006-13)

    @Test("OC-6083 a drag carrying only a file promise is refused and a drop of it is SHF-VAL-001")
    func promiseOnlyRefused() {
        let types = ["com.apple.NSFilePromiseItemMetadata", "com.apple.pasteboard.promised-file-url"]
        #expect(ShelfDropPlanner.acceptance(types: types, originatesInShelf: false) == .refused)
        #expect(code(plan(types, [])) == .shfVal001)
    }

    @Test("OC-6084 a colour swatch is refused and a drop of it is SHF-VAL-001")
    func colourOnlyRefused() {
        let types = ["com.apple.cocoa.pasteboard.color"]
        #expect(ShelfDropPlanner.acceptance(types: types, originatesInShelf: false) == .refused)
        #expect(code(plan(types, [])) == .shfVal001)
    }

    @Test("OC-6100 only unsupported types (a PDF data drag) is refused and stores nothing")
    func pdfOnlyRefused() {
        let types = ["com.adobe.pdf"]
        #expect(ShelfDropPlanner.acceptance(types: types, originatesInShelf: false) == .refused)
        #expect(code(plan(types, [PasteboardRepresentation(uti: "com.adobe.pdf", data: Data([1, 2, 3]))])) == .shfVal001)
    }

    @Test("OC-6085 OC-6086 each never-store marker refuses a drag that also carries text, and the text is not planned")
    func markersRefuse() {
        #expect(Set(PasteboardMarkers.neverStore).count == 3)
        for marker in PasteboardMarkers.neverStore {
            let types = [PasteboardTypes.plainText, marker]
            #expect(ShelfDropPlanner.acceptance(types: types, originatesInShelf: false) == .refused, "\(marker)")
            let result = plan(types, [text("secret-x")])
            #expect(code(result) == .shfVal001, "\(marker)")
            #expect(value(result) == nil, "\(marker) must not yield a candidate")
        }
    }

    @Test("OC-6087 a drag that began in the Shelf is refused silently whatever it carries")
    func shelfOriginRefusedSilently() {
        #expect(ShelfDropPlanner.acceptance(types: [PasteboardTypes.plainText], originatesInShelf: true) == .refusedSilently)
        #expect(ShelfDropPlanner.acceptance(types: ["com.adobe.pdf"], originatesInShelf: true) == .refusedSilently)
    }

    @Test("FR-006-12 text, an image, a file and a URL are each accepted")
    func honouredTypesAccepted() {
        for type in [PasteboardTypes.plainText, PasteboardTypes.png, PasteboardTypes.fileURL, PasteboardTypes.url] {
            #expect(ShelfDropPlanner.acceptance(types: [type], originatesInShelf: false) == .accepted, "\(type)")
        }
    }

    @Test("OC-6089 acceptance is decided from type identifiers alone: it takes no data, so hovering reads none")
    func acceptanceTakesTypesOnly() {
        // The signature is the guarantee (BR-4): `acceptance(types:originatesInShelf:)` has no data parameter, so a
        // lazy source is never asked for bytes while a drag hovers. The decision must not need them.
        #expect(ShelfDropPlanner.acceptance(types: [PasteboardTypes.plainText], originatesInShelf: false) == .accepted)
    }

    // MARK: What a drop becomes (FR-006-13, AC-006-14)

    @Test("OC-6090 three files dropped from Finder are one bundle of three with the source carried through")
    func threeFilesBundle() throws {
        try withFiles(["a.txt", "b.txt", "c.txt"]) { urls in
            let result = value(plan([PasteboardTypes.fileURL], urls.map(fileRep), source: finder))
            #expect(result?.candidate.kind == .bundle)
            #expect(result?.candidate.members.count == 3)
            #expect(result?.candidate.source == finder)
            #expect(result?.candidate.origin == .shelfDrop)
            #expect(result?.candidate.occurredAt == when)
            #expect(result?.skipped.isEmpty == true)
        }
    }

    @Test("OC-6091 dropped URL text is a link")
    func urlTextIsLink() {
        let result = value(plan([PasteboardTypes.plainText], [text("https://example.com/drop")]))
        #expect(result?.candidate.kind == .link)
        #expect(result?.candidate.plainText == "https://example.com/drop")
    }

    @Test("OC-6092 dropping the same files twice yields the same content key, so the second is a bump")
    func sameFilesSameKey() throws {
        try withFiles(["a.txt", "b.txt", "c.txt"]) { urls in
            let first = value(plan([PasteboardTypes.fileURL], urls.map(fileRep)))
            let second = value(plan([PasteboardTypes.fileURL], urls.map(fileRep)))
            #expect(first != nil)
            #expect(first?.candidate.contentKey == second?.candidate.contentKey)
        }
    }

    @Test("OC-6093 OC-6094 dropped text is planned whatever the source app is")
    func textPlannedForAnySource() {
        let textEdit = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
        let result = value(plan([PasteboardTypes.plainText], [text("curated-drop")], source: textEdit))
        #expect(result?.candidate.plainText == "curated-drop")
        #expect(result?.candidate.source == textEdit)
    }

    @Test("OC-6095 a dropped folder is a folder reference, never its contents")
    func folderIsReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-planner-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 4096).write(to: folder.appendingPathComponent("inner.bin"))

        let result = value(plan([PasteboardTypes.fileURL], [fileRep(folder)]))
        #expect(result?.candidate.kind == .folder)
        #expect(result?.candidate.members.map(\.isDirectory) == [true])
        #expect(result?.candidate.representations.isEmpty == true)
    }

    @Test("OC-6097 a drop is classified exactly as the same content copied: the same kind")
    func dropKindMatchesCapture() {
        let reps = [text("kind-probe@example.com")]
        let captured = CaptureClassifier.classify(reps)
        let dropped = value(plan([PasteboardTypes.plainText], reps))
        #expect(dropped?.candidate.kind == .email)
        if case .success(let classification) = captured {
            #expect(dropped?.candidate.kind == classification.kind)
            #expect(dropped?.candidate.contentKey == classification.contentKey)
        } else {
            Issue.record("the classifier rejected the probe text")
        }
    }

    // MARK: Partial and failed drops (FR-006-14, AC-006-16)

    @Test("OC-6099 an unreadable file is skipped with SHF-IO-001 and the readable ones are still planned")
    func unreadableSkipped() throws {
        try withFiles(["locked.txt", "huge.bin", "ok.txt"]) { urls in
            let locked = urls[0].standardizedFileURL.path
            let result = value(plan([PasteboardTypes.fileURL], urls.map(fileRep), isReadable: { $0 != locked }))
            #expect(result?.candidate.members.map(\.path).sorted() == [urls[1], urls[2]].map { $0.standardizedFileURL.path }.sorted())
            #expect(result?.skipped.map(\.code) == [.shfIo001])
            // Files are held by reference and never size-checked (FR-007-06): no limit error for the big one.
            #expect(result?.skipped.contains { $0.code == .shfLim001 } == false)
        }
    }

    @Test("OC-6099 one readable file out of two is a single file item, not a bundle")
    func singleSurvivorIsNotBundle() throws {
        try withFiles(["locked.txt", "ok.txt"]) { urls in
            let locked = urls[0].standardizedFileURL.path
            let result = value(plan([PasteboardTypes.fileURL], urls.map(fileRep), isReadable: { $0 != locked }))
            #expect(result?.candidate.kind == .file)
            #expect(result?.candidate.members.count == 1)
            #expect(result?.skipped.count == 1)
        }
    }

    @Test("OC-6101 a file deleted during the drag is SHF-IO-001 and the remaining file is planned")
    func deletedDuringDrag() throws {
        try withFiles(["gone.txt", "kept.txt"]) { urls in
            let reps = urls.map(fileRep)
            try FileManager.default.removeItem(at: urls[0])
            let gone = urls[0].standardizedFileURL.path
            let result = value(plan([PasteboardTypes.fileURL], reps, isReadable: { FileManager.default.isReadableFile(atPath: $0) && $0 != gone }))
            #expect(result?.candidate.members.count == 1)
            #expect(result?.skipped.map(\.code) == [.shfIo001])
        }
    }

    @Test("OC-6101 when every dropped file is gone or unreadable the drop fails with SHF-IO-001")
    func everyFileUnreadable() throws {
        try withFiles(["a.txt", "b.txt"]) { urls in
            let result = plan([PasteboardTypes.fileURL], urls.map(fileRep), isReadable: { _ in false })
            #expect(code(result) == .shfIo001)
        }
    }

    @Test("OC-6103 two readable files are a bundle and nothing is skipped")
    func twoReadableFiles() throws {
        try withFiles(["a.txt", "b.txt"]) { urls in
            let result = value(plan([PasteboardTypes.fileURL], urls.map(fileRep)))
            #expect(result?.candidate.kind == .bundle)
            #expect(result?.skipped.isEmpty == true)
        }
    }

    @Test("FR-006-14 an accepted type with nothing storable behind it is SHF-VAL-001, not a capture code")
    func nothingStorable() {
        #expect(code(plan([PasteboardTypes.plainText], [])) == .shfVal001)
    }

    @Test("OC-6101 files that pass the readability check but are gone when classified fail as SHF-IO-001, not a capture code")
    func goneAtClassification() throws {
        try withFiles(["gone.txt"]) { urls in
            let reps = urls.map(fileRep)
            try FileManager.default.removeItem(at: urls[0])
            #expect(code(plan([PasteboardTypes.fileURL], reps)) == .shfIo001)
        }
    }

    @Test("OC-6101 the all-unreadable failure records how many files were dropped")
    func allUnreadableCountsFiles() throws {
        try withFiles(["a.txt", "b.txt"]) { urls in
            guard case .failure(let error) = plan([PasteboardTypes.fileURL], urls.map(fileRep), isReadable: { _ in false }) else {
                Issue.record("expected a failure")
                return
            }
            #expect(error.context[.count] == .int(2))
        }
    }
}
