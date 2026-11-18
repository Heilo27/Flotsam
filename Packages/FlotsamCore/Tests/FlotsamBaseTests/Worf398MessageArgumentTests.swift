import Foundation
import Testing
@testable import FlotsamBase

// TASK-398 independent verification (Worf). A raised error renders through FlotsamStrings.message(for: FlotsamError),
// the same call ErrorReporter, FatalAlert and OrganizeCoordinator make. Contexts below are inputs; every expected
// string is a literal copied from FRD-000 section 7/8 and Localizable.xcstrings, never read from production code.
// Mutations that turn these red: (M1) a raise or the reader goes back to `.byteSize` for a ceiling; (M2) message(for:)
// goes back to appending every present key (a stray `.count` on a `{limit}` row); (M3) the `.text` slot stops being
// filled from `.limitBytes`.

private let fallback = "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About."

@Suite struct Worf398MessageArgumentTests {
    // MARK: {limit} rows take limitBytes

    @Test("OC-398-01 CAP-LIM-001 with a 10 MiB limitBytes reads '10 MB' from the catalogue")
    func capLim001Limit() {
        let error = FlotsamError(.capLim001, "t", context: [.limitBytes: .bytes(10_485_760)])
        #expect(FlotsamStrings.message(for: error) == "A copy was too large to save (over 10 MB). It is still on your clipboard.")
    }

    @Test("OC-398-02 SSP-LIM-001, SHF-LIM-001 and ORG-LIM-003 each render their own text with the 100 MB / 10 MB size")
    func otherLimitRows() {
        let image = FlotsamError(.sspLim001, "t", context: [.limitBytes: .bytes(104_857_600)])
        let drop = FlotsamError(.shfLim001, "t", context: [.limitBytes: .bytes(10_485_760)])
        let edit = FlotsamError(.orgLim003, "t", context: [.limitBytes: .bytes(10_485_760)])
        #expect(FlotsamStrings.message(for: image) == "A screenshot was too large to import (over 100 MB).")
        #expect(FlotsamStrings.message(for: drop) == "A dropped item was too large to save (over 10 MB).")
        #expect(FlotsamStrings.message(for: edit) == "That text is over the 10 MB limit. Shorten it and try again.")
    }

    // MARK: byteSize is a different quantity (negative / wrong-key)

    @Test("OC-398-03 a {limit} row raised with only the old byteSize key still falls back to SYS-INT-001 (declared slot unfilled)")
    func byteSizeAloneDoesNotFillLimit() {
        for code in [ErrorCode.capLim001, .sspLim001, .shfLim001, .orgLim003] {
            let error = FlotsamError(code, "t", context: [.byteSize: .bytes(10_485_760)])
            #expect(FlotsamStrings.message(for: error) == fallback, "\(code.rawValue)")
        }
    }

    @Test("OC-398-04 byteSize beside limitBytes is log-only: the limit is rendered, the byteSize ignored")
    func byteSizeIgnoredBesideLimit() {
        let error = FlotsamError(.capLim001, "t", context: [.limitBytes: .bytes(10_485_760), .byteSize: .bytes(999)])
        #expect(FlotsamStrings.message(for: error) == "A copy was too large to save (over 10 MB). It is still on your clipboard.")
    }

    @Test("OC-398-05 STO-IO-001 / STO-LIM-002 raised with a byteSize (free space) render their placeholder-free text")
    func byteSizeOnPlaceholderFreeRows() {
        let io = FlotsamError(.stoIo001, "t", context: [.byteSize: .bytes(4_096)])
        let low = FlotsamError(.stoLim002, "t", context: [.byteSize: .bytes(419_430_400)])
        #expect(FlotsamStrings.message(for: io) == "Flotsam couldn't write to its data folder. Check free disk space.")
        #expect(FlotsamStrings.message(for: low) == "Disk space is low, so Flotsam isn't saving images.")
    }

    // MARK: stray count (M2)

    @Test("OC-398-06 a stray count beside limitBytes on a {limit} row does not break the render")
    func strayCountOnLimitRow() {
        let error = FlotsamError(.capLim001, "t", context: [.count: .int(3), .limitBytes: .bytes(10_485_760)])
        #expect(FlotsamStrings.message(for: error) == "A copy was too large to save (over 10 MB). It is still on your clipboard.")
    }

    @Test("OC-398-07 a count on a row whose text states its own number is log-only: ORG-VAL-002 and ORG-LIM-002")
    func countOnPlaceholderFreeRows() {
        let note = FlotsamError(.orgVal002, "t", context: [.count: .int(2_000)])
        let tags = FlotsamError(.orgLim002, "t", context: [.count: .int(100)])
        #expect(FlotsamStrings.message(for: note) == "Notes can be up to 2,000 characters.")
        #expect(FlotsamStrings.message(for: tags) == "You can have up to 100 tags.")
    }

    // MARK: {n} row unchanged

    @Test("OC-398-08 CAP-LIM-003 takes count: 501 renders '501', 1 and 0 render their own numbers")
    func capLim003Count() {
        func text(_ n: Int) -> String { FlotsamStrings.message(for: FlotsamError(.capLim003, "t", context: [.count: .int(n)])) }
        #expect(text(501) == "A copy of 501 files was trimmed to the first 500.")
        #expect(text(1) == "A copy of 1 files was trimmed to the first 500.")
        #expect(text(0) == "A copy of 0 files was trimmed to the first 500.")
    }

    @Test("OC-398-09 CAP-LIM-003 with a stray limitBytes beside count still renders the count")
    func capLim003StrayLimit() {
        let error = FlotsamError(.capLim003, "t", context: [.count: .int(501), .limitBytes: .bytes(1_024)])
        #expect(FlotsamStrings.message(for: error) == "A copy of 501 files was trimmed to the first 500.")
    }

    // MARK: declared slot with nothing usable => fallback (negative / empty)

    @Test("OC-398-10 a declared slot with no context, or a value of the wrong type, falls back to SYS-INT-001")
    func missingOrWrongTypedValue() {
        #expect(FlotsamStrings.message(for: FlotsamError(.capLim001, "t")) == fallback)
        #expect(FlotsamStrings.message(for: FlotsamError(.capLim001, "t", context: [.limitBytes: .int(10_485_760)])) == fallback)
        #expect(FlotsamStrings.message(for: FlotsamError(.capLim003, "t")) == fallback)
        #expect(FlotsamStrings.message(for: FlotsamError(.capLim003, "t", context: [.count: .bytes(501)])) == fallback)
        #expect(FlotsamStrings.message(for: FlotsamError(.orgLim003, "t", context: [.count: .int(5)])) == fallback)
    }

    // MARK: size boundaries

    @Test("OC-398-11 limitBytes boundaries: 0, negative (same as 0), 1 KiB, 1 MiB, 1 MiB + 1 render literal sizes")
    func limitBoundaries() {
        func text(_ bytes: Int) -> String {
            FlotsamStrings.message(for: FlotsamError(.shfLim001, "t", context: [.limitBytes: .bytes(bytes)]))
        }
        // The unit word for zero is the formatter's (observed "0 bytes"); what matters here is digits, no "Zero", and negative == zero.
        #expect(text(0).hasPrefix("A dropped item was too large to save (over 0 "))
        #expect(!text(0).contains("Zero"))
        #expect(text(-5) == text(0))
        #expect(text(1_024) == "A dropped item was too large to save (over 1 KB).")
        #expect(text(1_048_576) == "A dropped item was too large to save (over 1 MB).")
        #expect(text(1_048_577) == "A dropped item was too large to save (over 1 MB).")
    }

    // MARK: exhaustive: no code with a catalogue message falls back given its declared context

    @Test("OC-398-12 every user-facing code whose template has a slot is filled by exactly the declared context, count and limit forms")
    func declaredSlotsFillable() {
        let slotCodes = ErrorCode.allCases.filter { !$0.messageArgumentKinds.isEmpty }
        #expect(Set(slotCodes.map(\.rawValue)) == ["CAP-LIM-001", "CAP-LIM-003", "ORG-LIM-003", "SHF-LIM-001", "SSP-LIM-001"])
        for code in slotCodes {
            let context: [LogKey: LogSafeValue] = code.messageArgumentKinds == [.integer]
                ? [.count: .int(7)] : [.limitBytes: .bytes(2_097_152)]
            let message = FlotsamStrings.message(for: FlotsamError(code, "t", context: context))
            #expect(message != fallback, "\(code.rawValue)")
            #expect(message.contains(code.messageArgumentKinds == [.integer] ? "7" : "2 MB"), "\(code.rawValue)")
        }
    }
}
