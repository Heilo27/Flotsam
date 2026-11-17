import Foundation
import Testing
@testable import FlotsamBase

/// FR-000-07 / AC-000-02: the code enum and the catalogue must be identical sets.
@Suite struct ErrorCatalogueTests {
    private static func catalogueStrings() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FlotsamBase/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = json?["strings"] as? [String: [String: Any]] ?? [:]
        return strings.compactMapValues { entry in
            let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            return (en?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }

    @Test func rawValuesAreUnique() {
        let raws = ErrorCode.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }

    @Test func rawValuesFollowCodeFormat() {
        for code in ErrorCode.allCases {
            let parts = code.rawValue.split(separator: "-")
            #expect(parts.count == 3 && parts[2].count == 3 && Int(parts[2]) != nil, "\(code.rawValue)")
        }
    }

    @Test func everyNonInfoCodeHasAMessageUnder140Characters() throws {
        let catalogue = try Self.catalogueStrings()
        for code in ErrorCode.allCases where code.severity != .info {
            let message = try #require(catalogue[code.catalogueKey], "\(code.rawValue) has no catalogue key")
            #expect(message.count <= 140, "\(code.rawValue) message is \(message.count) characters")
            #expect(FlotsamStrings.text(forKey: code.catalogueKey) == message)
        }
    }

    @Test func everyErrorCatalogueKeyHasACode() throws {
        let catalogue = try Self.catalogueStrings()
        let known = Set(ErrorCode.allCases.map(\.catalogueKey))
        for key in catalogue.keys where key.hasPrefix("error.") {
            #expect(known.contains(key), "\(key) has no ErrorCode")
        }
    }

    @Test func missingKeyFallsBackToInternalErrorText() {
        #expect(FlotsamStrings.text(forKey: "error.NOPE-XXX-999") == nil)
        #expect(!FlotsamStrings.message(for: .sysInt001).isEmpty)
    }
}
