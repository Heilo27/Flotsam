import Foundation
import Testing
import FlotsamBase
@testable import FlotsamPayload

/// Worf, FRD-004 FR-004-07 / FR-004-11: the classifiers Organize uses for edited text and ungrouped bundle members.
/// Expected values are literals (SHA-256 hex computed outside the code under test).
@Suite struct WorfCaptureClassifierTests {
    // AC-004-07. Red if the edit path stops running FR-001-09 detection, or keeps the old kind.
    @Test("AC-004-07 given text edited to a URL, when classified, then the kind is link and the key is the text key of those bytes")
    func editedUrlBecomesLink() {
        let result = CaptureClassifier.classifyEditedText("https://x.y")

        #expect(result.kind == .link)
        #expect(result.contentKey == "text:ef594cd7d5e15ababed93277a97988f6dbdc7b91b95343f7b4fcaaf09b12ffe3")
    }

    // Red if plain prose is mis-detected, or the fallback kind is not .text.
    @Test("AC-004-07 given ordinary words, when classified, then the kind is text")
    func editedProseIsText() {
        let result = CaptureClassifier.classifyEditedText("hello world")

        #expect(result.kind == .text)
        #expect(result.contentKey == "text:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    // Red if the key is computed from the trimmed text instead of the exact UTF-8 bytes (FR-001-15).
    @Test("AC-004-07 given trailing whitespace, when classified, then the key covers the exact bytes and the kind still detects on the trimmed text")
    func keyUsesExactBytesDetectionUsesTrimmed() {
        let spaced = CaptureClassifier.classifyEditedText("hello world ")
        let url = CaptureClassifier.classifyEditedText("  https://x.y\n")

        #expect(spaced.kind == .text)
        #expect(spaced.contentKey == "text:9e1b04359ce9f650852b7f468eb9cbaa8198d8678a7ddce5caaeb123b76439ff")
        #expect(spaced.contentKey != "text:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        #expect(url.kind == .link)
    }

    // Red if any typed kind FR-004-07 lists as editable stops being re-detected after an edit.
    @Test("AC-004-07 given an email, a colour and a phone number, when classified, then each is re-detected")
    func editedTypedKinds() {
        #expect(CaptureClassifier.classifyEditedText("a@b.co").kind == .email)
        #expect(CaptureClassifier.classifyEditedText("#ff0000").kind == .color)
        #expect(CaptureClassifier.classifyEditedText("(555) 123-4567").kind == .phone)
    }

    // B6: a multi-line string is never a typed kind (FR-001-09), and a partial match does not count.
    @Test("AC-004-07 given a URL on one line and words on the next, when classified, then it stays text")
    func multilineAndPartialMatchesStayText() {
        #expect(CaptureClassifier.classifyEditedText("https://x.y\nmore").kind == .text)
        #expect(CaptureClassifier.classifyEditedText("see https://x.y").kind == .text)
    }

    // AC-004-10 / FR-004-11. Red if a member's key stops equalling the one-path capture key (a later copy would not dedupe).
    @Test("AC-004-10 given a file member, when classified, then it is a file keyed like a one-path capture")
    func memberFile() {
        let result = CaptureClassifier.classifyMember(path: "/a/b", isDirectory: false)

        #expect(result.kind == .file)
        #expect(result.contentKey == "files:662b7b62a798bb2d53e67cad9778e12e48297c79eae98d3aae7197be825d768f")
    }

    // Red if directories are all treated as files, or a package is treated as a folder.
    @Test("AC-004-10 given a plain directory and a package directory, when classified, then the first is a folder and the second a file")
    func memberDirectoryVersusPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worf-member-\(UUID().uuidString)")
        let plain = root.appendingPathComponent("plain")
        let package = root.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CaptureClassifier.classifyMember(path: plain.path, isDirectory: true).kind == .folder)
        #expect(CaptureClassifier.classifyMember(path: package.path, isDirectory: true).kind == .file)
    }

    // B6 boundary: a directory that no longer exists on disk must not throw or crash, and is still a folder.
    @Test("AC-004-10 given a directory path that does not exist, when classified, then it is a folder")
    func memberMissingDirectory() {
        #expect(CaptureClassifier.classifyMember(path: "/nonexistent-worf/dir", isDirectory: true).kind == .folder)
    }

    // Red if the live classifier set is wired to the wrong function (e.g. fileMember to the text rules).
    @Test("AC-004-07/10 given the live classifier set, when both closures run, then they apply the edit and member rules")
    func liveClassifiersAreWired() {
        let edited = ItemClassifiers.live.editedText("https://x.y")
        let member = ItemClassifiers.live.fileMember("/z/c.txt", false)

        #expect(edited.kind == .link)
        #expect(member.kind == .file)
        #expect(member.contentKey == "files:614b997e68547d21750d1056ed4b2e80fe0a3f7ea5754840fbc7c38710fffb08")
    }
}
