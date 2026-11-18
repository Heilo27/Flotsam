import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-398 independent verification (Worf), observed at the layer the user reads: the real raise (IngestLimits.apply,
// editText, setNote, createTag) is handed to a real ErrorReporter and the Notice text the presenter receives is
// asserted. Expected strings are literals from FRD-000 section 7 / the catalogue. Mutation M1 (a raise goes back to
// `.byteSize`) turns the limit tests red; M2 (re-add a stray `.count` with the old append-all reader) turns the
// CAP-LIM-002 / bundle cases red.

@MainActor
private final class CapturingPresenter: ErrorPresenter {
    private(set) var notices: [Notice] = []
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) { self.notices = notices }
    func presentFatal(_ error: FlotsamError) {}
}

private func candidate(
    kind: ItemKind, origin: CaptureOrigin, text: String? = nil, image: Data? = nil, members: Int = 0
) -> IngestCandidate {
    IngestCandidate(
        kind: kind, contentKey: "k", plainText: text,
        representations: image.map { [PasteboardRepresentation(uti: "public.png", data: $0)] } ?? [],
        members: (0..<members).map { IngestMember(path: "/tmp/f\($0)", bookmark: nil, isDirectory: false) },
        origin: origin, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
}

/// What a user would read for one raised error: the Notice message after the reporter's own rendering.
@MainActor
private func noticeText(_ error: FlotsamError) async -> String? {
    let presenter = CapturingPresenter()
    let reporter = ErrorReporter(presenter: presenter, sink: NullSink())
    await reporter.report(error, origin: .background)
    return presenter.notices.first?.message
}

private struct NullSink: LogSink {
    func write(_ record: LogRecord) {}
}

@MainActor
@Suite struct Worf398IngestMessageTests {
    @Test("OC-398-20 over-ceiling pasteboard text and image reach the Notice as the CAP-LIM-001 text with 10 MB / 100 MB")
    func pasteboardNotices() async throws {
        guard case .failure(let text) = IngestLimits.apply(to: candidate(
            kind: .text, origin: .pasteboard, text: String(repeating: "a", count: 10_485_761)))
        else { Issue.record("text one byte over the ceiling was accepted"); return }
        guard case .failure(let image) = IngestLimits.apply(to: candidate(
            kind: .image, origin: .pasteboard, image: Data(count: 104_857_601)))
        else { Issue.record("image one byte over the ceiling was accepted"); return }
        #expect(await noticeText(text) == "A copy was too large to save (over 10 MB). It is still on your clipboard.")
        #expect(await noticeText(image) == "A copy was too large to save (over 100 MB). It is still on your clipboard.")
    }

    @Test("OC-398-21 over-ceiling screenshot and shelf drop reach the Notice as SSP-LIM-001 and SHF-LIM-001 text")
    func screenshotAndShelfNotices() async throws {
        guard case .failure(let shot) = IngestLimits.apply(to: candidate(
            kind: .screenshot, origin: .screenshotFile, image: Data(count: 104_857_601)))
        else { Issue.record("screenshot over the ceiling was accepted"); return }
        guard case .failure(let drop) = IngestLimits.apply(to: candidate(
            kind: .text, origin: .shelfDrop, text: String(repeating: "a", count: 10_485_761)))
        else { Issue.record("drop over the ceiling was accepted"); return }
        #expect(shot.code == .sspLim001)
        #expect(drop.code == .shfLim001)
        #expect(await noticeText(shot) == "A screenshot was too large to import (over 100 MB).")
        #expect(await noticeText(drop) == "A dropped item was too large to save (over 10 MB).")
    }

    @Test("OC-398-22 a candidate exactly at each ceiling is accepted (no error, so no notice)")
    func atCeilingAccepted() {
        for origin in [CaptureOrigin.pasteboard, .shelfDrop] {
            if case .failure(let error) = IngestLimits.apply(to: candidate(
                kind: .text, origin: origin, text: String(repeating: "a", count: 10_485_760))) {
                Issue.record("text at 10 MiB rejected with \(error.code.rawValue)")
            }
        }
        if case .failure(let error) = IngestLimits.apply(to: candidate(
            kind: .image, origin: .pasteboard, image: Data(count: 104_857_600))) {
            Issue.record("image at 100 MiB rejected with \(error.code.rawValue)")
        }
    }

    @Test("OC-398-23 an over-500-member bundle warns CAP-LIM-003 with the count, rendered '501 files'")
    func bundleTrimNotice() async throws {
        guard case .success(let limited) = IngestLimits.apply(to: candidate(kind: .bundle, origin: .pasteboard, members: 501))
        else { Issue.record("bundle trim should succeed with a warning"); return }
        let warning = try #require(limited.warnings.first { $0.code == .capLim003 })
        #expect(await noticeText(warning) == "A copy of 501 files was trimmed to the first 500.")
    }

    @Test("OC-398-24 organise rejections: 10 MiB + 1 edit, 2,001-character note and the 101st tag render their catalogue text")
    func organiseRejections() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2)])

        let classifiers = ItemClassifiers(
            editedText: { text in ItemClassification(kind: .text, contentKey: "edit:" + text) },
            fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })
        guard case .failure(let edit) = await store.database.editText(
            id: Store.id(2), to: String(repeating: "a", count: 10_485_761), classifiers: classifiers)
        else { Issue.record("oversized edit accepted"); return }
        guard case .failure(let note) = await store.database.setNote(String(repeating: "n", count: 2_001), for: Store.id(1))
        else { Issue.record("oversized note accepted"); return }
        for n in 1...100 { _ = try await store.database.createTag(name: "tag \(n)").get() }
        guard case .failure(let tag) = await store.database.createTag(name: "one more")
        else { Issue.record("101st tag accepted"); return }

        #expect(edit.code == .orgLim003)
        #expect(note.code == .orgVal002)
        #expect(tag.code == .orgLim002)
        #expect(FlotsamStrings.message(for: edit) == "That text is over the 10 MB limit. Shorten it and try again.")
        #expect(FlotsamStrings.message(for: note) == "Notes can be up to 2,000 characters.")
        #expect(FlotsamStrings.message(for: tag) == "You can have up to 100 tags.")
    }
}
