import FlotsamBase
import Testing
@testable import FlotsamTriggers

// TASK-444 (Worf, blind). The fake poster must apply PostGuard for ALL THREE post kinds, including the terminated
// check, so tests built on it see the same refusals as the real adapter. Expected values are literals.

@MainActor
@Suite("TASK-444 RecordingKeys applies PostGuard")
struct Worf444PostGuardFakeTests {
    private static let target = FrontmostApp(bundleId: "com.example.editor", processId: 100)
    private static let other = FrontmostApp(bundleId: "com.example.mail", processId: 200)

    private func keys(frontmost: FrontmostApp?, running: Bool) -> RecordingKeys {
        let k = RecordingKeys()
        k.frontmost = { frontmost }
        k.targetIsRunning = running
        return k
    }

    /// OC-444-W4. given the target is frontmost but terminated, when each post kind is attempted, then all return false and
    /// record nothing. Red if the fake stops passing `targetIsRunning` to PostGuard (or hard-codes true).
    @Test("OC-444-W4 terminated target: no post kind is recorded")
    func terminatedRecordsNothing() {
        let k = keys(frontmost: Self.target, running: false)
        #expect(k.postPaste(to: Self.target) == false)
        #expect(k.postKeyPress(keyCode: 51, count: 2, to: Self.target) == false)
        #expect(k.postText("abc", to: Self.target) == false)
        #expect(k.actions.isEmpty)
        #expect(k.targets.isEmpty)
    }

    /// OC-444-W5. given the target is frontmost and running, when each post kind is attempted, then exactly three
    /// posts are recorded, each addressed to the target. Red if the fake refuses a legitimate post.
    @Test("OC-444-W5 running frontmost target: all three post kinds recorded, addressed to it")
    func runningRecordsAll() {
        let k = keys(frontmost: Self.target, running: true)
        #expect(k.postPaste(to: Self.target))
        #expect(k.postKeyPress(keyCode: 51, count: 2, to: Self.target))
        #expect(k.postText("abc", to: Self.target))
        #expect(k.actions == [.paste, .key(51, count: 2), .text("abc")])
        #expect(k.targets == [Self.target, Self.target, Self.target])
    }

    /// OC-444-W6. given another app is frontmost, when posting to the target, then nothing is recorded; given focus then
    /// returns, the next post is recorded (count delta 0 then 1).
    @Test("OC-444-W6 other app frontmost: refused, then recorded once focus returns")
    func otherFrontmostThenReturn() {
        var front = Self.other
        let k = RecordingKeys()
        k.frontmost = { front }
        #expect(k.postPaste(to: Self.target) == false)
        #expect(k.actions.count == 0)
        front = Self.target
        #expect(k.postPaste(to: Self.target))
        #expect(k.actions == [.paste])
        #expect(k.targets == [Self.target])
    }
}
