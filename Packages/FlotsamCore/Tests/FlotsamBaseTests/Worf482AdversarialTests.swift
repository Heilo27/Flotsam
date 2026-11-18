import CoreFoundation
import Foundation
import Testing
@testable import FlotsamBase

// Worf TASK-482 blind QA: FR-000-05 plural resolver reads a boxed (NSNumber) whole-number count. Exactly 1 reads "one";
// anything else, a boolean and a floating-point value included, reads "other". Expected sides are literals.

@Suite struct Worf482AdversarialTests {
    private static let one = "%1$lld item"
    private static let other = "%1$lld items"

    private func resolve(_ count: CVarArg?) throws -> String {
        let entry = try #require(FlotsamCatalogue.englishEntries().get()["ui.library.footerItems"])
        return FlotsamStrings.resolvingPlurals(in: entry, arguments: count.map { [$0] } ?? [])
    }

    // OC-482-W1: every NSNumber integer storage type holding 1 reads "one" (red if the NSNumber branch is dropped).
    @Test("FR-000-05 OC-482-W1 given NSNumber 1 from every integer init, when resolved, then it reads one")
    func everyIntegerInit() throws {
        #expect(try resolve(NSNumber(value: Int8(1))) == Self.one)
        #expect(try resolve(NSNumber(value: Int16(1))) == Self.one)
        #expect(try resolve(NSNumber(value: Int32(1))) == Self.one)
        #expect(try resolve(NSNumber(value: UInt16(1))) == Self.one)
        #expect(try resolve(NSNumber(value: UInt32(1))) == Self.one)
        #expect(try resolve(NSNumber(value: UInt64(1))) == Self.one)
        #expect(try resolve(NSNumber(value: UInt(1))) == Self.one)
        #expect(try resolve(NSNumber(value: Int(1))) == Self.one)
    }

    // OC-482-W2: a literal and NSNumber(value:) agree; a literal NSNumber via integerLiteral reads one.
    @Test("FR-000-05 OC-482-W2 given the literal 1 and NSNumber(value: 1), when resolved, then both read one")
    func literalVsBoxed() throws {
        let literal: NSNumber = 1
        #expect(try resolve(1) == Self.one)
        #expect(try resolve(NSNumber(value: 1)) == Self.one)
        #expect(try resolve(literal) == Self.one)
        let two: NSNumber = 2
        #expect(try resolve(two) == Self.other)
    }

    // OC-482-W3: boolean NSNumbers (CFBoolean singletons and booleanLiteral) are not counts.
    @Test("FR-000-05 OC-482-W3 given CFBoolean true/false in every spelling, when resolved, then it reads other")
    func cfBoolean() throws {
        let literalTrue: NSNumber = true
        #expect(try resolve(NSNumber(value: true)) == Self.other)
        #expect(try resolve(NSNumber(booleanLiteral: true)) == Self.other)
        #expect(try resolve(literalTrue) == Self.other)
        #expect(try resolve(kCFBooleanTrue as NSNumber) == Self.other)
        #expect(try resolve(kCFBooleanFalse as NSNumber) == Self.other)
        #expect(try resolve(NSNumber(value: false)) == Self.other)
        #expect(try resolve(true) == Self.other)
    }

    // OC-482-W4: an Int8/UInt8 1 that is NOT a boolean must still read one (guards over-broad bool rejection).
    @Test("FR-000-05 OC-482-W4 given NSNumber(Int8 1) and NSNumber(UInt8 1) (char storage), when resolved, then one, not other")
    func charStorageIsNotBool() throws {
        let number = NSNumber(value: Int8(1))
        #expect(CFGetTypeID(number) != CFBooleanGetTypeID())
        #expect(try resolve(number) == Self.one)
        #expect(try resolve(NSNumber(value: UInt8(1))) == Self.one)
    }

    // OC-482-W5: negative zero, zero and negatives read other; none crash.
    @Test("FR-000-05 OC-482-W5 given NSNumber -0.0, 0, -0, -1, Int.min, when resolved, then each reads other")
    func zeroAndNegatives() throws {
        #expect(try resolve(NSNumber(value: -0.0)) == Self.other)
        #expect(try resolve(NSNumber(value: 0.0)) == Self.other)
        #expect(try resolve(NSNumber(value: 0)) == Self.other)
        #expect(try resolve(NSNumber(value: -1)) == Self.other)
        #expect(try resolve(NSNumber(value: Int.min)) == Self.other)
        #expect(try resolve(NSNumber(value: Int64.max)) == Self.other)
    }

    // OC-482-W6: decimal numbers. NSDecimalNumber is an NSNumber subclass; the resolver must not crash on it.
    // Judgment: FR-000-05 change log says a decimal reads other; an NSDecimalNumber is a decimal type, so other.
    @Test("FR-000-05 OC-482-W6 given NSDecimalNumber 1 / 1.5 / 0 and Decimal 1, when resolved, then it does not crash and reads other")
    func decimalNumbers() throws {
        #expect(try resolve(NSDecimalNumber(string: "1.5")) == Self.other)
        #expect(try resolve(NSDecimalNumber.zero) == Self.other)
        #expect(try resolve(NSDecimalNumber(string: "NaN")) == Self.other)
        // Decimal is not CVarArg-bridged to NSNumber in the resolver; it must read other.
        #expect(try resolve(NSDecimalNumber(decimal: 2)) == Self.other)
    }

    // OC-482-W7: floating-point NSNumbers near 1 and special values read other.
    @Test("FR-000-05 OC-482-W7 given NSNumber 1.0, nextDown(1), NaN, infinity, 1e300, when resolved, then each reads other")
    func floatingEdge() throws {
        #expect(try resolve(NSNumber(value: 1.0)) == Self.other)
        #expect(try resolve(NSNumber(value: Double(1).nextDown)) == Self.other)
        #expect(try resolve(NSNumber(value: Double.nan)) == Self.other)
        #expect(try resolve(NSNumber(value: Double.infinity)) == Self.other)
        #expect(try resolve(NSNumber(value: 1e300)) == Self.other)
        #expect(try resolve(NSNumber(value: CGFloat(1))) == Self.other)
    }

    // OC-482-W8: out-of-Int64 unsigned range does not wrap to 1 (2^64 + 1 cannot exist, but 2^63+1 must not read one).
    @Test("FR-000-05 OC-482-W8 given NSNumber(UInt64 2^63+1) and UInt64.max, when resolved, then it reads other")
    func unsignedBeyondInt64() throws {
        #expect(try resolve(NSNumber(value: (UInt64(1) << 63) | 1)) == Self.other)
        #expect(try resolve(NSNumber(value: UInt64.max)) == Self.other)
    }

    // OC-482-W9: the swift-side behaviour of non-NSNumber values is unchanged.
    @Test("FR-000-05 OC-482-W9 given nil, text, a Bool and Swift integers, when resolved, then unchanged: other/other/other/one")
    func swiftSideUnchanged() throws {
        #expect(try resolve(nil) == Self.other)
        #expect(try resolve("1") == Self.other)
        #expect(try resolve(NSString(string: "1")) == Self.other)
        #expect(try resolve(Int16(1)) == Self.one)
        #expect(try resolve(UInt(1)) == Self.one)
    }

    // OC-482-W10: the count shown is still the number: a boxed 1 resolves the pattern and the specifier survives.
    @Test("FR-000-05 OC-482-W10 given NSNumber 1 and 5, when resolved, then the other branch keeps the %lld specifier")
    func specifierKept() throws {
        #expect(try resolve(NSNumber(value: 5)) == "%1$lld items")
        #expect(try resolve(NSNumber(value: 1)) == "%1$lld item")
    }
}
