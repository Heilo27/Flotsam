import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShelf

// FRD-006 oracle contract tests, drag-out area (OC-6067..6073, 6075, 6076, 6078..6080, 6082).
// Everything below AppKit: the real ShelfDragPlanner, the real ShelfModel.covered(by:), and for OC-6078 a real
// database in a scratch folder. Expected values are the oracle's literals (URLs, UTIs, HUD text), never the
// planner's own expressions.
//
// Not testable below AppKit, so not here (marked "no seam: manual" in the report):
//   OC-6077 (the 4 pt gesture threshold is a private constant in App/Flotsam/Shelf/ShelfCardInteraction.swift),
//   OC-6081 (Esc / no-accept ends in ShelfDragOut.draggingSession(endedAt:), an NSDraggingSource callback).
// Each drag-out OC below that also names the clipboard changeCount or the drag operation mask has only its
// planner half tested: the planner has no pasteboard port at all, and the `.copy` mask is an AppKit callback.

/// A filesystem where exactly the listed paths exist. It also records every call that would change a file, so a
/// destructive-path test can assert that the originals were never touched.
private final class Frd006Files: FileSystemPort, @unchecked Sendable {
    private let lock = NSLock()
    private let existing: Set<String>
    private var calls: [String] = []

    init(existing: Set<String>) { self.existing = existing }

    /// Every create, copy, move, remove or write the code under test asked for.
    var mutations: [String] { lock.withLock { calls } }

    func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
    private func record(_ call: String) -> FlotsamResult<Void> {
        lock.withLock { calls.append(call) }
        return .failure(FlotsamError(.sysInt001, "mutation not expected in a drag-out test"))
    }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { record("create \(url.path)") }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { record("copy \(source.path)") }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { record("move \(source.path)") }
    func removeItem(at url: URL) -> FlotsamResult<Void> { record("remove \(url.path)") }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { record("write \(url.path)") }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { .failure(FlotsamError(.sysInt001, "unused")) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func readFile(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused")) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused")) }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

private func rep(_ uti: String, _ text: String) -> PasteboardRepresentation {
    PasteboardRepresentation(uti: uti, data: Data(text.utf8))
}

private func id(_ n: Int) -> UUID { shelfID(n) }

private func textCard(_ n: Int, _ text: String?, extra: [PasteboardRepresentation] = [], kind: ItemKind = .text) -> ShelfDragCandidate {
    ShelfDragCandidate(itemId: id(n), content: ItemContent(kind: kind, plainText: text, representations: extra, members: []))
}

private func fileCard(_ n: Int, kind: ItemKind = .bundle, _ paths: [String]) -> ShelfDragCandidate {
    ShelfDragCandidate(
        itemId: id(n),
        content: ItemContent(
            kind: kind, plainText: nil, representations: [],
            members: paths.map { ItemMember(path: $0, bookmark: nil, isDirectory: kind == .folder) }))
}

private func imageCard(_ n: Int, kind: ItemKind = .screenshot, _ reps: [PasteboardRepresentation]) -> ShelfDragCandidate {
    ShelfDragCandidate(itemId: id(n), content: ItemContent(kind: kind, plainText: nil, representations: reps, members: []))
}

private func fileURLItem(_ n: Int, _ url: String) -> ShelfDragItem {
    ShelfDragItem(itemId: id(n), payload: .representations([rep("public.file-url", url)]))
}

private func plan(_ cards: [ShelfDragCandidate], on files: Frd006Files) -> FlotsamResult<ShelfDragPlan> {
    ShelfDragPlanner.plan(cards, files: files)
}

private func failure(_ result: FlotsamResult<ShelfDragPlan>) -> FlotsamError? {
    if case .failure(let error) = result { return error }
    return nil
}

private let goneHUD = "The original file or folder has moved or been deleted."
private let abortHUD = "Couldn't drag that item out. Try again or paste it from the Library."

private final class ScratchSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

private final class ScratchKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

@Suite struct Frd006ContractDragTests {
    // MARK: Images

    // OC-6067. given a screenshot card, when it is dragged, then the pasteboard item is the image (so Mail attaches it
    // inline) and exactly one card is dragged. Red if the planner offers the wrong representation, a second item,
    // or no image at all. The changeCount half has no seam: the planner has no pasteboard port.
    @Test("OC-6067 a screenshot card drags as one image item, PNG preferred, then TIFF, then JPEG")
    func oc6067_screenshotDragsAsImage() throws {
        let png = rep("public.png", "png-bytes")
        let tiff = rep("public.tiff", "tiff-bytes")
        let jpeg = rep("public.jpeg", "jpeg-bytes")
        let files = Frd006Files(existing: [])

        let all = try plan([imageCard(1, [jpeg, tiff, png])], on: files).get()
        #expect(all.items == [ShelfDragItem(itemId: id(1), payload: .image(png))])
        #expect(all.draggedItemIds == [id(1)])

        let noPNG = try plan([imageCard(1, [jpeg, tiff])], on: files).get()
        #expect(noPNG.items.map(\.payload) == [.image(tiff)])
        let onlyJPEG = try plan([imageCard(1, [jpeg])], on: files).get()
        #expect(onlyJPEG.items.map(\.payload) == [.image(jpeg)])
        #expect(files.mutations.isEmpty)
    }

    // OC-6067 negative. An image card with no readable image data has nothing to drag: LIB-DAT-001, no items.
    @Test("OC-6067 an image card holding no image data does not start a drag")
    func oc6067_imageWithoutImageData() {
        let result = plan([imageCard(1, [rep("public.rtf", "not an image")])], on: Frd006Files(existing: []))
        #expect(failure(result)?.code == .libDat001)
    }

    // MARK: Files

    // OC-6068. given a bundle card of 3 files, when it is dragged, then 3 file URLs go on the drag pasteboard from
    // one card, and no original is created, copied, moved or removed. Red if a member is dropped or duplicated, or if
    // the planner touches the files.
    @Test("OC-6068 a bundle of three drags as three file URLs from one card and touches no original")
    func oc6068_bundleOfThree() throws {
        let paths = ["/Frd006/a.txt", "/Frd006/b.txt", "/Frd006/c.txt"]
        let files = Frd006Files(existing: Set(paths))
        let result = try plan([fileCard(1, paths)], on: files).get()
        #expect(result.items == [
            fileURLItem(1, "file:///Frd006/a.txt"), fileURLItem(1, "file:///Frd006/b.txt"), fileURLItem(1, "file:///Frd006/c.txt"),
        ])
        #expect(result.draggedItemIds == [id(1)])
        #expect(files.mutations.isEmpty)
    }

    // OC-6068 boundary. A bundle of one member is one item; a bundle of 4 is four (0/1/many).
    @Test("OC-6068 one member gives one item and four members give four")
    func oc6068_memberCountBoundaries() throws {
        let one = try plan([fileCard(1, ["/Frd006/a"])], on: Frd006Files(existing: ["/Frd006/a"])).get()
        #expect(one.items == [fileURLItem(1, "file:///Frd006/a")])
        let four = ["/Frd006/a", "/Frd006/b", "/Frd006/c", "/Frd006/d"]
        let many = try plan([fileCard(1, four)], on: Frd006Files(existing: Set(four))).get()
        #expect(many.items.count == 4)
        #expect(many.items.map(\.itemId) == [id(1), id(1), id(1), id(1)])
    }

    // OC-6070. given a file card whose original sits on the same volume (Finder would move), when dragged, then the
    // pasteboard carries only the file URL for a copy and the planner changes nothing on disk. Red if the planner
    // moves, removes or rewrites the original. The `.copy` operation mask is AppKit (no seam).
    @Test("OC-6070 a file card drags as a file URL only and the original is never moved or removed")
    func oc6070_sameVolumeFileIsNotMoved() throws {
        let files = Frd006Files(existing: ["/Frd006/same-volume.pdf"])
        let result = try plan([fileCard(1, kind: .file, ["/Frd006/same-volume.pdf"])], on: files).get()
        #expect(result.items == [fileURLItem(1, "file:///Frd006/same-volume.pdf")])
        #expect(files.mutations.isEmpty)
        #expect(files.fileExists(at: URL(fileURLWithPath: "/Frd006/same-volume.pdf")))
    }

    // OC-6071. given a file or folder or bundle card, when it is dragged (with or without modifiers), then nothing
    // that could become a move, alias or symlink is offered: the only type is public.file-url. Red if the planner adds
    // an alias or bookmark representation. The modifier handling itself (`ignoreModifierKeys`) is AppKit (no seam).
    @Test("OC-6071 file-backed cards offer public.file-url and no alias, bookmark or symlink type")
    func oc6071_noAliasTypes() throws {
        for kind in [ItemKind.file, .folder, .bundle] {
            let files = Frd006Files(existing: ["/Frd006/x"])
            let result = try plan([fileCard(1, kind: kind, ["/Frd006/x"])], on: files).get()
            let utis = result.items.flatMap { item -> [String] in
                guard case .representations(let written) = item.payload else { return ["<not a representations payload>"] }
                return written.map(\.uti)
            }
            #expect(utis == ["public.file-url"], "\(kind)")
            #expect(files.mutations.isEmpty, "\(kind)")
        }
    }

    // OC-6073. given a bundle of 3 with 1 missing, when dragged, then the target gets the 2 existing file URLs. Red if
    // a missing member is dragged, or if one missing member drops the whole card. Each position is tried.
    @Test("OC-6073 a bundle with one member missing drags the two that exist, whichever one is gone")
    func oc6073_missingMemberSkipped() throws {
        let paths = ["/Frd006/a", "/Frd006/b", "/Frd006/c"]
        let expected: [[String]] = [
            ["file:///Frd006/b", "file:///Frd006/c"],
            ["file:///Frd006/a", "file:///Frd006/c"],
            ["file:///Frd006/a", "file:///Frd006/b"],
        ]
        for (missing, urls) in expected.enumerated() {
            var existing = Set(paths)
            existing.remove(paths[missing])
            let result = try plan([fileCard(1, paths)], on: Frd006Files(existing: existing)).get()
            #expect(result.items == urls.map { fileURLItem(1, $0) }, "missing member \(missing)")
            #expect(result.draggedItemIds == [id(1)], "missing member \(missing)")
        }
    }

    // MARK: Text

    // OC-6069. given text card 'drag-text-1', when dragged, then one item carries exactly that text. Red if the text
    // is altered or a second item appears. Boundary: multi-line, emoji and quote characters survive untouched. The
    // changeCount half has no seam (no pasteboard port).
    @Test("OC-6069 a text card drags its text, unaltered, as one item")
    func oc6069_textCard() throws {
        let files = Frd006Files(existing: [])
        let result = try plan([textCard(1, "drag-text-1")], on: files).get()
        #expect(result.items == [ShelfDragItem(itemId: id(1), payload: .representations([rep("public.utf8-plain-text", "drag-text-1")]))])
        #expect(result.cardCount == 1)

        // Boundary: multi-line and non-ASCII text is offered exactly as stored, still as one item.
        let awkward = "line one\nline two \u{1F30A} \"quoted\""
        let multi = try plan([textCard(1, awkward)], on: files).get()
        #expect(multi.items == [ShelfDragItem(itemId: id(1), payload: .representations([rep("public.utf8-plain-text", awkward)]))])
    }

    // OC-6075. given text card '{date}', when dragged, then the literal '{date}' is offered. Red if the planner
    // expands variables the way a trigger does.
    @Test("OC-6075 a text card containing a trigger variable drags the literal text")
    func oc6075_variablesStayLiteral() throws {
        for literal in ["{date}", "{clipboard}", "a {date} b"] {
            let result = try plan([textCard(1, literal)], on: Frd006Files(existing: [])).get()
            #expect(result.items.map(\.payload) == [.representations([rep("public.utf8-plain-text", literal)])], "\(literal)")
        }
    }

    // OC-6076. given a rich-text card with bold, when dragged, then the RTF and HTML bytes travel with the plain text,
    // unchanged and in that order, so the target keeps the bold. Red if a stored representation is dropped, reordered
    // or rewritten. Negative: a rich card with no stored formatting offers plain text only.
    @Test("OC-6076 a rich-text card keeps its stored formatting representations, byte for byte")
    func oc6076_richTextKeepsFormatting() throws {
        let rtf = rep("public.rtf", "{\\rtf1\\b bold\\b0}")
        let html = rep("public.html", "<b>bold</b>")
        let files = Frd006Files(existing: [])
        let result = try plan([textCard(1, "bold", extra: [rtf, html], kind: .richText)], on: files).get()
        #expect(result.items.map(\.payload) == [.representations([rep("public.utf8-plain-text", "bold"), rtf, html])])

        let plainOnly = try plan([textCard(1, "bold", kind: .richText)], on: files).get()
        #expect(plainOnly.items.map(\.payload) == [.representations([rep("public.utf8-plain-text", "bold")])])
    }

    // MARK: Several cards

    // OC-6072. given 3 text cards selected (clicked out of order), when dragged, then the target gets 3 items in the
    // cards' on-screen order. Red if the order follows click order, or if pinned cards do not come first.
    @MainActor
    @Test("OC-6072 three selected cards drag as three items in on-screen order, not click order")
    func oc6072_onScreenOrder() async throws {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, pinned: true), makeShelfRow(3)])
        await rig.openSticky()
        rig.model.click(shelfID(3))
        rig.model.click(shelfID(1), modifiers: .command)
        rig.model.click(shelfID(2), modifiers: .command)

        let covered = rig.model.covered(by: shelfID(1))
        #expect(covered.map(\.id) == [shelfID(2), shelfID(1), shelfID(3)])

        let cards = covered.map { textCard(Int($0.primaryLine.dropFirst(5)) ?? 0, $0.primaryLine) }
        let result = try plan(cards, on: Frd006Files(existing: [])).get()
        #expect(result.items.count == 3)
        #expect(result.items.map(\.itemId) == [shelfID(2), shelfID(1), shelfID(3)])
        #expect(result.items.map(\.payload) == [
            .representations([rep("public.utf8-plain-text", "item 2")]),
            .representations([rep("public.utf8-plain-text", "item 1")]),
            .representations([rep("public.utf8-plain-text", "item 3")]),
        ])
    }

    // MARK: Drag-out accepted (AC-006-12)

    // OC-6078. given a transient Shelf and cards A and B, when they are dragged into TextEdit, then each card's paste
    // count rises by exactly 1 (a 3-file bundle once, not three times; a card whose file is gone not at all) and the
    // Shelf hides. The loop that records the paste mirrors ShelfDragOut.draggingSession(endedAt:), which calls
    // recordPaste once per `draggedItemIds`. Red if the plan lists a card per pasteboard item, or lists a card that
    // contributed nothing. lastUsedAt is not readable through ItemRow, so only the count is checked here.
    @Test("OC-6078 an accepted drag counts one paste per contributing card and hides a transient Shelf")
    func oc6078_acceptedDragCountsPastes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frd006-drag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let filesFolder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data"), logSink: ScratchSink()).get()
        let ingest = IngestActor(database: database, settings: SettingsStore(store: ScratchKV()))

        func store(types: [String], _ reps: [PasteboardRepresentation], at seconds: TimeInterval) async throws -> UUID {
            let dropPlan = try ShelfDropPlanner.plan(
                types: types, representations: reps, source: nil,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds), isReadable: { _ in true }).get()
            switch try await ingest.ingest(dropPlan.candidate).get().outcome {
            case .created(let itemId), .bumped(let itemId), .unchanged(let itemId): return itemId
            }
        }
        func fileRep(_ name: String) throws -> PasteboardRepresentation {
            let url = filesFolder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return PasteboardRepresentation(uti: "public.file-url", data: Data(url.absoluteString.utf8))
        }
        let textTypes = ["public.utf8-plain-text"]
        let fileTypes = ["public.file-url"]

        let a = try await store(types: textTypes, [rep("public.utf8-plain-text", "drag card A")], at: 1)
        let bundle = try await store(types: fileTypes, [fileRep("m1.txt"), fileRep("m2.txt"), fileRep("m3.txt")], at: 2)
        let gone = try await store(types: fileTypes, [fileRep("gone.txt")], at: 3)
        let b = try await store(types: textTypes, [rep("public.utf8-plain-text", "drag card B")], at: 4)

        var cards: [ShelfDragCandidate] = []
        var survivors = Set<String>()
        for itemId in [a, bundle, gone, b] {
            let content = try await database.content(of: itemId).get()
            cards.append(ShelfDragCandidate(itemId: itemId, content: content))
            if itemId != gone { survivors.formUnion(content.members.map(\.path)) }
        }
        let dragPlan = try plan(cards, on: Frd006Files(existing: survivors)).get()
        #expect(dragPlan.draggedItemIds == [a, bundle, b])
        #expect(dragPlan.items.count == 5)

        for itemId in dragPlan.draggedItemIds { _ = await database.recordPaste(of: itemId) }

        let rows = try await database.items(matching: LibraryQuery()).get().rows
        #expect(rows.count == 4)
        let counts = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.pasteCount) })
        #expect(counts[a] == 1)
        #expect(counts[b] == 1)
        #expect(counts[bundle] == 1)
        #expect(counts[gone] == 0)

        var machine = ShelfRevealMachine()
        let start = Date(timeIntervalSinceReferenceDate: 3_000_000)
        _ = machine.send(.configure(enabled: true, placement: .rightEdge, revealOnEdgeHover: false), at: start)
        _ = machine.send(.dragging(true), at: start.addingTimeInterval(1))
        _ = machine.send(.pointer(.edgeZone(screen: 0)), at: start.addingTimeInterval(1))
        _ = machine.advance(to: start.addingTimeInterval(1.3))
        #expect(machine.isVisible)
        #expect(machine.send(.dragOutAccepted, at: start.addingTimeInterval(2)) == [.hide])
        #expect(!machine.isVisible)
    }

    // MARK: Errors

    // OC-6079. given a bundle whose members are all deleted, when dragged, then no plan exists (so no drag image and no
    // drop) and the HUD is the LIB-DAT-001 text. Red if the planner still plans an empty item, or returns another
    // code. Boundary: with one member left the drag does start.
    @Test("OC-6079 a bundle with every member deleted does not start a drag and raises LIB-DAT-001")
    func oc6079_allMembersGone() throws {
        let paths = ["/Frd006/a", "/Frd006/b", "/Frd006/c"]
        let error = try #require(failure(plan([fileCard(1, paths)], on: Frd006Files(existing: []))))
        #expect(error.code == .libDat001)
        #expect(FlotsamStrings.message(for: error) == goneHUD)
        #expect(FlotsamStrings.message(for: .libDat001) == goneHUD)

        let oneLeft = try plan([fileCard(1, paths)], on: Frd006Files(existing: ["/Frd006/b"])).get()
        #expect(oneLeft.items == [fileURLItem(1, "file:///Frd006/b")])
    }

    // OC-6080. given a file card whose file was deleted, when dragged, then no drag starts and the HUD is LIB-DAT-001.
    // Red if a stale URL is still offered. Positive control: the same card with the file present does drag.
    @Test("OC-6080 a file or folder card whose original is gone does not start a drag")
    func oc6080_deletedFile() throws {
        for kind in [ItemKind.file, .folder] {
            let card = fileCard(1, kind: kind, ["/Frd006/deleted"])
            let error = try #require(failure(plan([card], on: Frd006Files(existing: []))), "\(kind)")
            #expect(error.code == .libDat001, "\(kind)")
            #expect(FlotsamStrings.message(for: error) == goneHUD, "\(kind)")
            #expect(error.context[.itemId] == .id(id(1)), "\(kind)")

            // A folder's URL carries the trailing slash `URL(fileURLWithPath:isDirectory: true)` gives it.
            let expectedURL = kind == .folder ? "file:///Frd006/deleted/" : "file:///Frd006/deleted"
            let present = try plan([card], on: Frd006Files(existing: ["/Frd006/deleted"])).get()
            #expect(present.items == [fileURLItem(1, expectedURL)], "\(kind)")
        }
    }

    // OC-6082. given nothing the planner can drag, when the drag is asked for, then SHF-OS-001 with its HUD text and
    // no plan (so no paste is recorded). Only the planner's SHF-OS-001 path is testable here: a system drag abort is
    // an AppKit event (no seam). A selection whose card is no longer on the Shelf covers nothing, which is how the
    // planner is reached empty.
    @MainActor
    @Test("OC-6082 nothing to drag is SHF-OS-001 with the catalogue HUD text and no plan")
    func oc6082_nothingToDrag() async throws {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2)])
        await rig.openSticky()
        let covered = rig.model.covered(by: shelfID(9))
        #expect(covered.isEmpty)

        let result = plan(covered.map { textCard(0, $0.primaryLine) }, on: Frd006Files(existing: []))
        let error = try #require(failure(result))
        #expect(error.code == .shfOs001)
        #expect(FlotsamStrings.message(for: error) == abortHUD)
        #expect(FlotsamStrings.message(for: .shfOs001) == abortHUD)
        #expect(failure(plan([textCard(1, "x")], on: Frd006Files(existing: []))) == nil)
    }
}
