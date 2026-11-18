import Foundation
import Testing
@testable import FlotsamBase

// Worf TASK-476 blind QA: FlotsamStrings.resolvingPlurals must pick the `one` form for a count of exactly 1 whatever the
// integer width or signedness, and `other` for everything else. Expected sides are literals ("item" / "items").

@Suite struct Worf476PluralWidthAdversarialTests {
    private static let one = "%1$lld item"
    private static let other = "%1$lld items"

    private func resolve(_ count: CVarArg?) throws -> String {
        let entry = try #require(FlotsamCatalogue.englishEntries().get()["ui.library.footerItems"])
        return FlotsamStrings.resolvingPlurals(in: entry, arguments: count.map { [$0] } ?? [])
    }

    // OC-476-W1: every integer width and signedness equal to 1 reads "one".
    @Test("FR-000-05 OC-476-W1 given a count of 1 in any integer width, when resolved, then it reads the one form")
    func oneInEveryWidth() throws {
        #expect(try resolve(Int(1)) == Self.one)
        #expect(try resolve(Int8(1)) == Self.one)
        #expect(try resolve(Int16(1)) == Self.one)
        #expect(try resolve(Int32(1)) == Self.one)
        #expect(try resolve(Int64(1)) == Self.one)
        #expect(try resolve(UInt(1)) == Self.one)
        #expect(try resolve(UInt8(1)) == Self.one)
        #expect(try resolve(UInt16(1)) == Self.one)
        #expect(try resolve(UInt32(1)) == Self.one)
        #expect(try resolve(UInt64(1)) == Self.one)
    }

    // OC-476-W2: zero, two, negatives and boundaries are never "one" in any width.
    @Test("FR-000-05 OC-476-W2 given counts other than 1 in any width, when resolved, then they read the other form")
    func notOneInEveryWidth() throws {
        #expect(try resolve(Int8(0)) == Self.other)
        #expect(try resolve(UInt32(0)) == Self.other)
        #expect(try resolve(Int8(-1)) == Self.other)
        #expect(try resolve(Int(-1)) == Self.other)
        #expect(try resolve(Int64(-1)) == Self.other)
        #expect(try resolve(Int16(2)) == Self.other)
        #expect(try resolve(UInt8(2)) == Self.other)
        #expect(try resolve(Int64.min) == Self.other)
        #expect(try resolve(Int64.max) == Self.other)
        #expect(try resolve(Int8.min) == Self.other)
        #expect(try resolve(UInt8.max) == Self.other)
        #expect(try resolve(UInt32.max) == Self.other)
        #expect(try resolve(UInt64.max) == Self.other)
        #expect(try resolve(UInt64(Int64.max) + 1) == Self.other)
    }

    // OC-476-W3: a value that is above Int's range but whose low bits equal 1 must not wrap to "one".
    @Test("FR-000-05 OC-476-W3 given an unsigned count above Int.max with low bit 1, when resolved, then it does not wrap to one")
    func noWrapAround() throws {
        #expect(try resolve(UInt64(1) << 63 | 1) == Self.other)
        #expect(try resolve(UInt(1) << 63 | 1) == Self.other)
    }

    // OC-476-W4: a non-integer, missing or out-of-range count takes "other".
    @Test("FR-000-05 OC-476-W4 given a missing or text count, when resolved, then it reads the other form")
    func missingAndText() throws {
        #expect(try resolve(nil) == Self.other)
        #expect(try resolve("1") == Self.other)
        #expect(try resolve(true) == Self.other)
    }

    // OC-476-W5: floating-point counts are not integers; the FRD says counts are integers, so 1.0 is "other".
    @Test("FR-000-05 OC-476-W5 given Double/Float 1.0, when resolved, then it reads the other form (not an integer)")
    func floatingPoint() throws {
        #expect(try resolve(Double(1.0)) == Self.other)
        #expect(try resolve(Float(1.0)) == Self.other)
    }

    // OC-476-W6: KNOWN (Minor, latent): NSNumber counts read "one" under the old `as? Int` (Foundation bridging) but read
    // "other" under the BinaryInteger cast. No shipped caller passes NSNumber (counts are Int). Red (known issue clears)
    // when the resolver also bridges NSNumber; then drop withKnownIssue.
    @Test("FR-000-05 OC-476-W6 KNOWN: NSNumber(1) as the count reads other (regression vs as? Int); no shipped caller boxes counts")
    func nsNumber() throws {
        let boxedOne = try resolve(NSNumber(value: 1))
        withKnownIssue("BinaryInteger cast does not bridge NSNumber(1), which `as? Int` did") {
            #expect(boxedOne == Self.one)
        }
        #expect(try resolve(NSNumber(value: 2)) == Self.other)
    }

    // OC-476-W7: the public formatted path agrees with the raw resolver for widths.
    @Test("FR-000-05 OC-476-W7 given Int32(1) through the public path, when formatted, then it reads 1 item")
    func publicPath() {
        #expect(FlotsamStrings.formatted(forKey: "ui.library.footerItems", [Int32(1)]) == "1 item")
        #expect(FlotsamStrings.formatted(forKey: "ui.library.footerItems", [UInt8(1)]) == "1 item")
        #expect(FlotsamStrings.formatted(forKey: "ui.library.footerItems", [Int64(2)]) == "2 items")
    }
}
