import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// FRD-003 8T, contract OC-3017 (AC-003-05): the primary line of a row, one item of each kind. Items go through the
// shipping ingest and query layer, so the line is what the Library reads, not what a fake supplied. The expected side
// is a literal from .claude/oracle/frd-003-contract.json (blind).

@MainActor
@Suite struct Frd003ContractRowTests {
    /// The oracle writes "120 x 80" in ASCII; the product may use a multiplication sign. Compare the shape, not the glyph.
    private func ascii(_ line: String) -> String { line.replacingOccurrences(of: "×", with: "x") }

    // OC-3017. Mutation: the text cut changes (3 lines, or 200 characters), a link shows a title instead of the URL,
    // the colour drops its hex, an image drops its pixel size, a bundle names 3 members or drops the count.
    @Test("OC-3017 every kind shows its primary line: 2 lines and 140 characters, the URL, the hex, the size, the names")
    func oc3017_primaryLinePerKind() async throws {
        // given: one item of each kind, as the contract seeds them
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let threeLines = String(repeating: "A", count: 99) + "\n" + String(repeating: "B", count: 99) + "\n" + String(repeating: "C", count: 99)
        let png120 = [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 120, height: 80))]
        let png1440 = [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 1440, height: 900))]
        func member(_ name: String, dir: Bool = false) -> IngestMember {
            IngestMember(path: "/tmp/oc3017/\(name)", bookmark: nil, isDirectory: dir)
        }
        let id: [String: UUID] = [
            "text": try await lib.add(.text, key: "k-text", text: threeLines, secondsAgo: 11).itemId,
            "short": try await lib.add(.text, key: "k-short", text: "one\ntwo\nthree", secondsAgo: 12).itemId,
            "rich": try await lib.add(.richText, key: "k-rich", text: threeLines + "R", secondsAgo: 13).itemId,
            "link": try await lib.add(.link, key: "k-link", text: "https://example.com/a", secondsAgo: 14).itemId,
            "color": try await lib.add(.color, key: "k-color", text: "#1A2b3C", secondsAgo: 15).itemId,
            "phone": try await lib.add(.phone, key: "k-phone", text: "+1 (415) 555-0100", secondsAgo: 16).itemId,
            "email": try await lib.add(.email, key: "k-email", text: "a@b.co", secondsAgo: 17).itemId,
            "image": try await lib.add(.image, key: "k-image", secondsAgo: 18, representations: png120).itemId,
            "screenshot": try await lib.add(
                .screenshot, key: "k-shot", secondsAgo: 19, representations: png1440, originalPath: "/tmp/oc3017/shot.png").itemId,
            "file": try await lib.add(.file, key: "k-file", secondsAgo: 20, members: [member("a.txt")]).itemId,
            "folder": try await lib.add(.folder, key: "k-folder", secondsAgo: 21, members: [member("Docs", dir: true)]).itemId,
            "bundle": try await lib.add(
                .bundle, key: "k-bundle", secondsAgo: 22, members: ["b1.txt", "b2.txt", "b3.txt"].map { member($0) }).itemId,
        ]
        // when: the Library is opened and its rows are read
        await lib.model.open(target: FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242))
        let rows = try await lib.allRows()
        func line(_ name: String) -> String { rows.first { $0.id == id[name] }?.primaryLine ?? "<missing row>" }
        // then: all twelve rows are listed, each with the line the contract names
        #expect(rows.count == 12)
        #expect(line("text") == String(repeating: "A", count: 99) + "\n" + String(repeating: "B", count: 40))
        #expect(line("text").count == 140)
        #expect(line("short") == "one\ntwo")
        #expect(line("rich") == String(repeating: "A", count: 99) + "\n" + String(repeating: "B", count: 40))
        #expect(line("link") == "https://example.com/a")
        #expect(line("color") == "#1A2b3C")
        #expect(line("phone") == "+1 (415) 555-0100")
        #expect(line("email") == "a@b.co")
        #expect(ascii(line("image")) == "Image 120 x 80")
        #expect(ascii(line("screenshot")) == "Screenshot 1440 x 900")
        #expect(line("file") == "a.txt")
        #expect(line("folder") == "Docs")
        let bundle = line("bundle")
        #expect(bundle.hasPrefix("3 items"))
        #expect(bundle.contains("b1.txt") && bundle.contains("b2.txt"))
        #expect(!bundle.contains("b3.txt"))
        #expect(lib.reported.errors.isEmpty)
    }
}
