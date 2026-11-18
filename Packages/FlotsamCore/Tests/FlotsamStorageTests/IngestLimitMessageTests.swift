import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-398: a too-large copy must reach the user as the catalogue text with its size, not the SYS-INT-001 fallback.
// Observed end to end: the candidate goes through IngestLimits.apply and the error it returns is rendered exactly as
// ErrorReporter renders it (FlotsamStrings.message(for: FlotsamError)). Expected strings are literals from FRD-000 section 8.

private let fallback = "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About."

private func candidate(kind: ItemKind, origin: CaptureOrigin, text: String? = nil, image: Data? = nil) -> IngestCandidate {
    IngestCandidate(
        kind: kind, contentKey: "k", plainText: text,
        representations: image.map { [PasteboardRepresentation(uti: "public.png", data: $0)] } ?? [],
        origin: origin, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
}

private func skipError(_ candidate: IngestCandidate) -> FlotsamError? {
    if case .failure(let error) = IngestLimits.apply(to: candidate) { return error }
    return nil
}

@Suite struct IngestLimitMessageTests {
    private let overText = String(repeating: "a", count: IngestLimits.maxTextBytes + 1)

    @Test("CAP-LIM-001 over-ceiling pasteboard text renders its catalogue text with the 10 MB size")
    func capLim001Text() throws {
        let error = try #require(skipError(candidate(kind: .text, origin: .pasteboard, text: overText)))
        #expect(error.code == .capLim001)
        #expect(FlotsamStrings.message(for: error) == "A copy was too large to save (over 10 MB). It is still on your clipboard.")
    }

    @Test("CAP-LIM-001 over-ceiling pasteboard image renders the 100 MB size")
    func capLim001Image() throws {
        let image = Data(count: IngestLimits.maxImageBytes + 1)
        let error = try #require(skipError(candidate(kind: .image, origin: .pasteboard, image: image)))
        #expect(error.code == .capLim001)
        #expect(FlotsamStrings.message(for: error) == "A copy was too large to save (over 100 MB). It is still on your clipboard.")
    }

    @Test("SSP-LIM-001 over-ceiling screenshot renders its catalogue text with the 100 MB size")
    func sspLim001() throws {
        let image = Data(count: IngestLimits.maxImageBytes + 1)
        let error = try #require(skipError(candidate(kind: .screenshot, origin: .screenshotFile, image: image)))
        #expect(error.code == .sspLim001)
        #expect(FlotsamStrings.message(for: error) == "A screenshot was too large to import (over 100 MB).")
    }

    @Test("SHF-LIM-001 over-ceiling shelf drop renders its catalogue text with the 10 MB size")
    func shfLim001() throws {
        let error = try #require(skipError(candidate(kind: .text, origin: .shelfDrop, text: overText)))
        #expect(error.code == .shfLim001)
        #expect(FlotsamStrings.message(for: error) == "A dropped item was too large to save (over 10 MB).")
    }

    @Test("the three skip codes never render the SYS-INT-001 fallback, whatever the ceiling that tripped")
    func skipCodesNeverFallBack() throws {
        let overImage = Data(count: IngestLimits.maxImageBytes + 1)
        let skips = [
            candidate(kind: .text, origin: .pasteboard, text: overText),
            candidate(kind: .image, origin: .pasteboard, image: overImage),
            candidate(kind: .text, origin: .shelfDrop, text: overText),
            candidate(kind: .image, origin: .shelfDrop, image: overImage),
            candidate(kind: .text, origin: .screenshotFile, text: overText),
            candidate(kind: .screenshot, origin: .screenshotFile, image: overImage),
        ]
        for skip in skips {
            let error = try #require(skipError(skip))
            #expect(FlotsamStrings.message(for: error) != fallback, "\(error.code.rawValue)")
        }
    }

    @Test("a text exactly at the ceiling is accepted, so no skip message is raised")
    func atCeilingAccepted() {
        let atLimit = String(repeating: "a", count: IngestLimits.maxTextBytes)
        #expect(skipError(candidate(kind: .text, origin: .pasteboard, text: atLimit)) == nil)
    }
}
