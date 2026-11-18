import Foundation
import Testing
import FlotsamBase
import FlotsamStorage
@testable import FlotsamPaste

// TASK-435 integration onto PasteGate (ADR-0005): the decision is PasteGate's; prompt-once is a side effect on the
// denied branch. A second denied paste must not call `request` again, and must return the same copy-only outcome.

@MainActor
@Suite("TASK-435: second denied paste does not request Accessibility again")
struct Task435SecondDenialTests {
    static let target = FrontmostApp(bundleId: "com.apple.Notes", processId: 42)

    private func makeService(probe: Worf435Probe, keys: FakeKeys) -> PasteService {
        let content = ItemContent(
            kind: .text, plainText: "hello",
            representations: [PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("hello".utf8))], members: [])
        return PasteService(
            store: FakeStore(.success(content)), pasteboard: FakePasteboard(), files: FakeFiles(existing: []),
            frontmost: FakeFrontmost(target: Self.target), accessibility: probe, keys: keys,
            clock: RecordingClock(), ownWrites: OwnWriteLedger())
    }

    @Test("two denied pastes: one request, both copy-only, no key posted")
    func secondDeniedPasteDoesNotRequestAgain() async throws {
        let probe = Worf435Probe(trusted: false)
        let keys = FakeKeys()
        let service = makeService(probe: probe, keys: keys)
        let host = FakeHost()

        let first = try await service.paste(itemId: UUID(), mode: .paste, target: Self.target, host: host).get()
        #expect(first == .copiedAccessibilityDenied)
        #expect(probe.requests == [.accessibility])

        let second = try await service.paste(itemId: UUID(), mode: .paste, target: Self.target, host: host).get()
        #expect(second == .copiedAccessibilityDenied)
        #expect(probe.requests == [.accessibility])
        #expect(keys.posts == 0)
    }
}
