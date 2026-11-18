import Foundation
import Testing
@testable import FlotsamPayload

// FRD-001 FR-001-12: a `public.file-url` representation is the URL string as UTF-8. The one parse is shared by clipboard
// capture and the Shelf drop's readability check (FR-006-14), so it is pinned here directly.

@Suite struct PasteboardFileURLTests {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    @Test("a file URL string yields that file URL")
    func parsesFileURL() {
        #expect(PasteboardTypes.fileURL(from: data("file:///srv/example/a.txt"))?.path == "/srv/example/a.txt")
    }

    @Test("surrounding whitespace and a trailing newline are ignored")
    func trimsWhitespace() {
        #expect(PasteboardTypes.fileURL(from: data("  file:///srv/example/a.txt\n"))?.path == "/srv/example/a.txt")
    }

    @Test("a URL that is not a file URL is not accepted")
    func rejectsNonFileURL() {
        #expect(PasteboardTypes.fileURL(from: data("https://example.com/a.txt")) == nil)
    }

    @Test("empty data is not accepted")
    func rejectsEmpty() {
        #expect(PasteboardTypes.fileURL(from: Data()) == nil)
    }
}
