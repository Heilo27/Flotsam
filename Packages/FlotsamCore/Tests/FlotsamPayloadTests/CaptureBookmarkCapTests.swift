import Foundation
import Testing
import FlotsamBase
@testable import FlotsamPayload

/// TASK-402, FRD-001 FR-001-12: capture creates bookmarks only for the first 500 members; later members are kept by
/// path so ingest reports the true count. Real files in a temp directory, removed after each test.
@Suite struct CaptureBookmarkCapTests {
    /// Runs `body` with `count` real files named in copy order, and always removes the directory afterwards.
    private func withFiles(_ count: Int, _ body: ([URL]) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotsam-bookmark-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<count).map { index -> URL in
            let url = directory.appendingPathComponent(String(format: "f%04d.txt", index))
            try Data().write(to: url)
            return url
        }
        try body(urls)
    }

    private func classify(_ urls: [URL]) -> FlotsamResult<Classification> {
        CaptureClassifier.classify(urls.map {
            PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data($0.absoluteString.utf8))
        })
    }

    @Test("the ceiling is the one Base value, 500")
    func ceilingIsFiveHundred() {
        #expect(BundleLimits.maxMembers == 500)
    }

    // Boundary 0: no file URL at all is not a file capture (FR-001-08), so nothing is bookmarked and nothing is kept.
    @Test("given no files, when classified, then it fails CAP-VAL-001 and creates no members")
    func zeroFiles() throws {
        try withFiles(0) { urls in
            guard case .failure(let error) = classify(urls) else { Issue.record("expected a failure"); return }
            #expect(error.code == .capVal001)
        }
    }

    // Boundary 1.
    @Test("given 1 file, when classified, then it is one member with a bookmark")
    func oneFile() throws {
        try withFiles(1) { urls in
            guard case .success(let result) = classify(urls) else { Issue.record("expected success"); return }
            #expect(result.members.count == 1)
            #expect(result.members.allSatisfy { $0.bookmark != nil })
            #expect(result.contentKey == ContentKey.files(paths: urls.map { $0.standardizedFileURL.path }))
        }
    }

    // Boundary 500: the last member that still gets a bookmark. Red if the cap is off by one downwards.
    @Test("given exactly 500 files, when classified, then all 500 are members and every one has a bookmark")
    func exactlyAtCeiling() throws {
        try withFiles(500) { urls in
            guard case .success(let result) = classify(urls) else { Issue.record("expected success"); return }
            #expect(result.members.count == 500)
            #expect(result.members.allSatisfy { $0.bookmark != nil })
            #expect(result.contentKey == ContentKey.files(paths: urls.map { $0.standardizedFileURL.path }))
        }
    }

    // Boundary 501: red if the cap is removed (member 501 would get a bookmark) or if the extra member is dropped.
    @Test("given 501 files, when classified, then all 501 stay listed, the first 500 have bookmarks and member 501 has none")
    func oneOverCeiling() throws {
        try withFiles(501) { urls in
            guard case .success(let result) = classify(urls) else { Issue.record("expected success"); return }
            let expectedPaths = urls.map { $0.standardizedFileURL.path }
            #expect(result.members.count == 501)
            #expect(result.members.map(\.path) == expectedPaths)
            #expect(result.members.prefix(500).allSatisfy { $0.bookmark != nil })
            #expect(result.members[500].bookmark == nil)
            #expect(result.members[500].isDirectory == false)
            #expect(result.contentKey == ContentKey.files(paths: expectedPaths))
        }
    }
}
