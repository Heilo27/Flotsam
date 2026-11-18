import Foundation
import Testing
@testable import FlotsamBase

// TASK-482 (FR-000-05): the plural resolver reads an integer-valued NSNumber count like the matching Swift integer.
// Expected sides are literals. Bool decision: a Bool is not a count, so NSNumber(true) (bridges to 1) reads "other".

@Suite struct Task482NSNumberPluralTests {
    private static let one = "%1$lld item"
    private static let other = "%1$lld items"

    private func resolve(_ count: CVarArg) throws -> String {
        let entry = try #require(FlotsamCatalogue.englishEntries().get()["ui.library.footerItems"])
        return FlotsamStrings.resolvingPlurals(in: entry, arguments: [count])
    }

    @Test("FR-000-05 TASK-482 NSNumber integer 1 in every storage width reads one")
    func integerOneEveryWidth() throws {
        #expect(try resolve(NSNumber(value: Int(1))) == Self.one)
        #expect(try resolve(NSNumber(value: Int8(1))) == Self.one)
        #expect(try resolve(NSNumber(value: Int64(1))) == Self.one)
        #expect(try resolve(NSNumber(value: UInt8(1))) == Self.one)
        #expect(try resolve(NSNumber(value: UInt64(1))) == Self.one)
    }

    @Test("FR-000-05 TASK-482 NSNumber 2 and 1.5 read other")
    func otherCounts() throws {
        #expect(try resolve(NSNumber(value: 2)) == Self.other)
        #expect(try resolve(NSNumber(value: 1.5)) == Self.other)
    }

    @Test("FR-000-05 TASK-482 NSNumber 0, -1, and values that truncate or wrap toward 1 read other")
    func boundaries() throws {
        #expect(try resolve(NSNumber(value: 0)) == Self.other)
        #expect(try resolve(NSNumber(value: -1)) == Self.other)
        #expect(try resolve(NSNumber(value: UInt64.max)) == Self.other)
        #expect(try resolve(NSNumber(value: 1.0000001)) == Self.other)
    }

    @Test("FR-000-05 TASK-482 a floating-point NSNumber 1.0 reads other, matching Double(1.0)")
    func floatingOne() throws {
        #expect(try resolve(NSNumber(value: 1.0)) == Self.other)
        #expect(try resolve(NSNumber(value: Float(1.0))) == Self.other)
    }

    @Test("FR-000-05 TASK-482 Bool is not a count: NSNumber(true), NSNumber(false) and Swift Bool read other")
    func boolIsNotACount() throws {
        #expect(try resolve(NSNumber(value: true)) == Self.other)
        #expect(try resolve(NSNumber(value: false)) == Self.other)
        #expect(try resolve(true) == Self.other)
    }

    @Test("FR-000-05 TASK-482 Swift Int and Int32 keep reading one; a String '1' reads other")
    func existingBehaviourKept() throws {
        #expect(try resolve(Int(1)) == Self.one)
        #expect(try resolve(Int32(1)) == Self.one)
        #expect(try resolve("1") == Self.other)
    }
}
