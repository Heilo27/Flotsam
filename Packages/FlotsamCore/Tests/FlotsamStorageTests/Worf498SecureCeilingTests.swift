import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-498 blind QA (Worf), FR-001-25: a secure clip's ciphertext is at most 64 KB (65,536 bytes); one byte over is
// skipped with the pasteboard limit code. Expected side is literals (65_536 and the error code), no production symbol.

private func secureCandidate(ciphertextBytes: Int, origin: CaptureOrigin = .pasteboard) -> IngestCandidate {
    IngestCandidate(
        secure: SealedSecret(ciphertext: Data(repeating: 0xAB, count: ciphertextBytes), fingerprint: "f"),
        source: nil, origin: origin, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
}

@Suite struct Worf498SecureCeilingTests {
    /// Red if the `>` becomes `>=` (the ceiling would reject a legal 64 KB ciphertext) or the check is removed.
    @Test("FR-001-25 W498-C1: a 65,536-byte ciphertext is kept, 65,537 bytes is skipped with CAP-LIM-001, 1 byte is kept")
    func ceilingBoundary() {
        #expect(IngestLimits.apply(to: secureCandidate(ciphertextBytes: 65_536)).isSuccessValue)
        #expect(IngestLimits.apply(to: secureCandidate(ciphertextBytes: 1)).isSuccessValue)

        guard case .failure(let error) = IngestLimits.apply(to: secureCandidate(ciphertextBytes: 65_537)) else {
            Issue.record("65,537 bytes of ciphertext was not skipped")
            return
        }
        #expect(error.code == .capLim001)
    }

    /// Red if the ceiling is applied to the wrong origin code or ignored for a Shelf drop.
    @Test("FR-001-25 W498-C2: the over-ceiling skip for a Shelf drop carries the Shelf limit code")
    func shelfOriginCode() {
        guard case .failure(let error) = IngestLimits.apply(to: secureCandidate(ciphertextBytes: 70_000, origin: .shelfDrop)) else {
            Issue.record("70,000 bytes of ciphertext was not skipped")
            return
        }
        #expect(error.code == .shfLim001)
    }

    /// Red if the ceiling leaks into ordinary text (a 100 KB ordinary text is far under its own 10 MB ceiling).
    @Test("FR-001-25 W498-C3: an ordinary 100 KB text is not held to the secure ceiling")
    func ordinaryTextUnaffected() {
        let candidate = IngestCandidate(
            kind: .text, contentKey: "k", plainText: String(repeating: "a", count: 100_000), origin: .pasteboard,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(IngestLimits.apply(to: candidate).isSuccessValue)
    }
}

private extension Result {
    var isSuccessValue: Bool { if case .success = self { true } else { false } }
}
