import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 FR-000-09/10/11 observed through the pure mapping and rendering functions (no OSLogStore): what the log
// line would carry in the clear versus `<private>`. Expected values are literals.

@Suite struct LogLevelAndPrivacyTests {
    // MARK: OC-0032

    /// OC-0032. given each severity, then the OSLog level is Info 1, Warning 0 (default/notice), Error 16, Fatal 17.
    @Test("OC-0032 severity maps to info, notice, error, fault")
    func levelMapping() {
        #expect(FlotsamLog.level(for: .info).rawValue == 1)
        #expect(FlotsamLog.level(for: .warning).rawValue == 0)
        #expect(FlotsamLog.level(for: .error).rawValue == 16)
        #expect(FlotsamLog.level(for: .fatal).rawValue == 17)
    }

    /// OC-0032 via codes. given real codes of each severity, then the level their severity yields matches.
    @Test("OC-0032 CAP-POL-001, CAP-LIM-001, CAP-IO-001 and STO-IO-002 log at 1, 0, 16, 17")
    func levelsViaCodes() {
        #expect(FlotsamLog.level(for: ErrorCode.capPol001.severity).rawValue == 1)
        #expect(FlotsamLog.level(for: ErrorCode.capLim001.severity).rawValue == 0)
        #expect(FlotsamLog.level(for: ErrorCode.capIo001.severity).rawValue == 16)
        #expect(FlotsamLog.level(for: ErrorCode.stoIo002.severity).rawValue == 17)
    }

    // MARK: OC-0036, OC-0071, OC-0072

    /// OC-0036. given a pasteboard-processed context with a source app, then outcome, kind, byte size and the
    /// system-declared UTI render in the clear and the bundle identifier renders only in the private part.
    @Test("OC-0036 public part carries outcome, kind, size and system UTI; bundle id is private")
    func publicPrivateSplit() throws {
        let bundle = try #require(BundleIdentifier("com.flotsamtest.markbid1"))
        let rendered = FlotsamLog.render([
            .byteSize: .bytes(12), .kind: .kind(.text), .outcome: .outcome(.stored),
            .uti: .uti(PasteboardTypeID("public.utf8-plain-text")), .bundleId: .bundleId(bundle),
        ])
        #expect(rendered.publicPart == "byteSize=12B kind=text outcome=stored uti=public.utf8-plain-text")
        #expect(rendered.privatePart == "bundleId=com.flotsamtest.markbid1")
        #expect(!rendered.publicPart.contains("markbid1"))
    }

    /// OC-0036 item id. given an item id, then it is private; counts and durations are public.
    @Test("OC-0036 item ids are private; counts, durations, booleans and codes are public")
    func itemIdPrivateCountsPublic() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let rendered = FlotsamLog.render([
            .itemId: .id(id), .count: .int(3), .durationMs: .milliseconds(250), .code: .code(.capPol001),
            .permission: .permission(.accessibility), .step: .bool(true),
        ])
        #expect(rendered.privatePart == "itemId=6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(rendered.publicPart == "code=CAP-POL-001 count=3 durationMs=250ms permission=accessibility step=true")
    }

    /// OC-0071. given a non-system UTI, then it renders private and never in the public part.
    @Test("OC-0071 a non-system UTI renders private")
    func nonSystemUTIPrivate() {
        let rendered = FlotsamLog.render([.uti: .uti(PasteboardTypeID("com.flotsamtest.markuti1.payload"))])
        #expect(rendered.publicPart == "")
        #expect(rendered.privatePart == "uti=com.flotsamtest.markuti1.payload")
    }

    /// OC-0072. given a `dyn.` identifier, a near-miss of a system UTI and a wrong-case system UTI, then each is
    /// private; given a representative of the closed system list, then it is public.
    @Test("OC-0072 dyn. and near-miss identifiers are private; closed-list identifiers are public", arguments: [
        ("dyn.ah62d4rv4ge81k4pxsq", false),
        ("public.utf8-plain-text.extra", false),
        ("PUBLIC.PNG", false),
        ("", false),
        ("public.png", true),
        ("com.apple.rtfd", true),
        ("NSStringPboardType", true),
        ("public.file-url", true),
    ])
    func utiClassification(identifier: String, expectedPublic: Bool) {
        let rendered = FlotsamLog.render([.uti: .uti(PasteboardTypeID(identifier))])
        if expectedPublic {
            #expect(rendered.publicPart == "uti=\(identifier)")
            #expect(rendered.privatePart == "")
        } else {
            #expect(rendered.publicPart == "")
            #expect(rendered.privatePart == "uti=\(identifier)")
        }
    }

    /// OC-0036 empty. given no context, then both parts are empty.
    @Test("OC-0036 empty context renders two empty parts")
    func emptyContext() {
        let rendered = FlotsamLog.render([:])
        #expect(rendered.publicPart == "")
        #expect(rendered.privatePart == "")
    }

    // MARK: OC-0073 (runtime half)

    /// OC-0073. given candidate bundle identifiers, then only reverse-DNS shaped ones of at most 255 bytes construct.
    @Test("OC-0073 BundleIdentifier accepts reverse-DNS shapes and rejects text, URLs, paths, emails", arguments: [
        ("com.apple.TextEdit", true),
        ("a.b", true),
        ("com.my-app.x1", true),
        ("com apple.TextEdit", false),
        ("https://example.com/path", false),
        ("/Users/someone/secret.txt", false),
        ("someone@example.com", false),
        ("nodots", false),
        ("", false),
        ("a..b", false),
        (".a.b", false),
        ("a.b.", false),
        ("com.café.app", false),
        ("com.apple.TextEdit:1", false),
    ])
    func bundleIdentifierShape(candidate: String, accepted: Bool) {
        #expect((BundleIdentifier(candidate) != nil) == accepted, "\(candidate)")
    }

    /// OC-0073 length boundary. given 255 and 256 byte identifiers, then 255 is accepted and 256 rejected.
    @Test("OC-0073 BundleIdentifier length boundary is 255 bytes")
    func bundleIdentifierLength() {
        let accepted = "a." + String(repeating: "b", count: 253)
        let rejected = "a." + String(repeating: "b", count: 254)
        #expect(accepted.utf8.count == 255)
        #expect(BundleIdentifier(accepted)?.value == accepted)
        #expect(BundleIdentifier(rejected) == nil)
    }

    // MARK: OC-0037, OC-0038, OC-0039 (event shape)

    /// Name, category and fields for each mandatory callsite.
    @Test("OC-0037 OC-0038 OC-0039 each event has a stable name, category and only safe fields", arguments: [
        (LogEvent.pasteboardProcessed(kind: .text, byteSize: 12, outcome: .stored, policy: nil), "pasteboard.processed", "capture", "byteSize=12B kind=text outcome=stored"),
        (LogEvent.pasteboardProcessed(kind: .text, byteSize: 12, outcome: .deduped, policy: nil), "pasteboard.processed", "capture", "byteSize=12B kind=text outcome=deduped"),
        (LogEvent.pasteboardProcessed(kind: nil, byteSize: 0, outcome: .skipped, policy: .capPol001), "pasteboard.processed", "capture", "byteSize=0B code=CAP-POL-001 outcome=skipped"),
        (LogEvent.screenshotImported(outcome: .succeeded, byteSize: 2048), "screenshot.imported", "screenshots", "byteSize=2048B outcome=succeeded"),
        (LogEvent.pasteBack(outcome: .failed), "paste.back", "library", "outcome=failed"),
        (LogEvent.hotkeyRegistered(outcome: .registered), "hotkey.registered", "triggers", "outcome=registered"),
        (LogEvent.shelf(.dragOut, outcome: .draggedOut), "shelf.dragOut", "shelf", "outcome=draggedOut"),
        (LogEvent.triggerMatched(true), "trigger.matched", "triggers", "outcome=matched"),
        (LogEvent.triggerMatched(false), "trigger.matched", "triggers", "outcome=noMatch"),
        (LogEvent.permissionChanged(.accessibility, granted: false), "permission.changed", "settings", "outcome=denied permission=accessibility"),
        (LogEvent.retentionSwept(rows: 5, bytes: 2048), "retention.swept", "storage", "byteSize=2048B rows=5"),
        (LogEvent.database(.migrate, outcome: .migrated), "database.migrate", "storage", "outcome=migrated"),
    ])
    func eventShape(event: LogEvent, name: String, category: String, publicLine: String) {
        #expect(event.name == name)
        #expect(event.category.rawValue == category)
        let rendered = FlotsamLog.render(event.fields)
        #expect(rendered.publicPart == publicLine)
        #expect(rendered.privatePart == "", "an event may carry no private value")
    }

    // MARK: OC-0004 (underlying error)

    /// OC-0004. given a system error whose description embeds a path, then only its domain and code are kept.
    @Test("OC-0004 UnderlyingErrorInfo keeps only domain and code of an NSError")
    func underlyingKeepsDomainAndCode() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [NSLocalizedDescriptionKey: "/Users/someone/secret.txt could not be saved"])
        let info = UnderlyingErrorInfo(error)
        #expect(info.domain == "NSCocoaErrorDomain")
        #expect(info.code == 640)
        #expect(info == UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 640))
        #expect(FlotsamError(.stoDb001, "test", underlying: info).underlying?.code == 640)
    }

    // MARK: OC-0031 (category mapping)

    /// OC-0031. given a code of each module, then its log category is that module's category, and the closed set of
    /// categories is exactly the nine named.
    @Test("OC-0031 each module's codes log under its own category; nine categories exist")
    func categoryMapping() {
        #expect(ErrorCode.sysInt001.logCategory.rawValue == "core")
        #expect(ErrorCode.capOs001.logCategory.rawValue == "capture")
        #expect(ErrorCode.sspIo001.logCategory.rawValue == "screenshots")
        #expect(ErrorCode.libOs001.logCategory.rawValue == "library")
        #expect(ErrorCode.orgVal001.logCategory.rawValue == "organize")
        #expect(ErrorCode.trgVal001.logCategory.rawValue == "triggers")
        #expect(ErrorCode.shfOs001.logCategory.rawValue == "shelf")
        #expect(ErrorCode.stoDb001.logCategory.rawValue == "storage")
        #expect(ErrorCode.setOs001.logCategory.rawValue == "settings")
        #expect(Set(LogCategory.allCases.map(\.rawValue)) == ["core", "capture", "screenshots", "library", "organize", "triggers", "shelf", "storage", "settings"])
    }
}
