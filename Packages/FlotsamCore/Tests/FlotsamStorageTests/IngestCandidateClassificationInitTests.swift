import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FR-006-12: clipboard capture and the Shelf drop build their IngestCandidate from a Classification through one init,
// so the two cannot drift. Observed here: every classified field arrives, members are mapped one for one in order,
// the caller's source, origin and time are used, and the screenshot-only fields keep their defaults.

@Suite struct IngestCandidateClassificationInitTests {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)
    private let source = SourceApp(bundleId: "com.apple.finder", name: "Finder")

    @Test("every classified field is carried into the candidate")
    func carriesEveryField() {
        let rep = PasteboardRepresentation(uti: "public.rtf", data: Data([1, 2, 3]))
        let classification = Classification(
            kind: .richText, contentKey: "key-1", plainText: "hello", representations: [rep], members: [])

        let candidate = IngestCandidate(
            classification: classification, source: source, origin: .shelfDrop, occurredAt: when)

        #expect(candidate.kind == .richText)
        #expect(candidate.contentKey == "key-1")
        #expect(candidate.plainText == "hello")
        #expect(candidate.representations == [rep])
        #expect(candidate.members.isEmpty)
    }

    @Test("members map one for one, in order, with path, bookmark and directory flag")
    func mapsMembers() {
        let bookmark = Data([9, 9])
        let classification = Classification(
            kind: .bundle, contentKey: "k", plainText: nil, representations: [],
            members: [
                ClassifiedMember(path: "/a/one.txt", bookmark: bookmark, isDirectory: false),
                ClassifiedMember(path: "/a/dir", bookmark: nil, isDirectory: true),
            ])

        let candidate = IngestCandidate(
            classification: classification, source: nil, origin: .pasteboard, occurredAt: when)

        #expect(candidate.members == [
            IngestMember(path: "/a/one.txt", bookmark: bookmark, isDirectory: false),
            IngestMember(path: "/a/dir", bookmark: nil, isDirectory: true),
        ])
    }

    @Test("source, origin and time come from the caller")
    func callerSuppliedFields() {
        let classification = Classification(
            kind: .text, contentKey: "k", plainText: "x", representations: [], members: [])

        let drop = IngestCandidate(classification: classification, source: source, origin: .shelfDrop, occurredAt: when)
        let paste = IngestCandidate(classification: classification, source: nil, origin: .pasteboard, occurredAt: when + 5)

        #expect(drop.source == source)
        #expect(drop.origin == .shelfDrop)
        #expect(drop.occurredAt == when)
        #expect(paste.source == nil)
        #expect(paste.origin == .pasteboard)
        #expect(paste.occurredAt == when + 5)
    }

    @Test("screenshot-only fields keep their defaults")
    func screenshotDefaults() {
        let classification = Classification(
            kind: .text, contentKey: "k", plainText: "x", representations: [], members: [])

        let candidate = IngestCandidate(
            classification: classification, source: nil, origin: .pasteboard, occurredAt: when)

        #expect(candidate.originalPath == nil)
        #expect(candidate.countsAsCopy == true)
    }
}
