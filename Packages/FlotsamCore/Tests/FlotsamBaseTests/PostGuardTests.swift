import Testing
@testable import FlotsamBase

// ADR-0005 / FR-003-16 / FR-005-14 (TASK-444). The decision the real CGEventKeyPoster makes before every postToPid,
// extracted so it can be tested without the App target. Expected values are literals.

@Suite("PostGuard (TASK-444)")
struct PostGuardTests {
    private static let target = FrontmostApp(bundleId: "com.example.editor", processId: 100)
    private static let other = FrontmostApp(bundleId: "com.example.mail", processId: 200)

    @Test("target frontmost and running: post")
    func targetFrontmostAndRunning() {
        #expect(PostGuard.allowsPost(to: Self.target, frontmost: Self.target, targetIsRunning: true))
    }

    @Test("another app frontmost: refuse")
    func anotherAppFrontmost() {
        #expect(!PostGuard.allowsPost(to: Self.target, frontmost: Self.other, targetIsRunning: true))
    }

    @Test("target frontmost but terminated or not found: refuse")
    func targetTerminated() {
        #expect(!PostGuard.allowsPost(to: Self.target, frontmost: Self.target, targetIsRunning: false))
    }

    @Test("no frontmost app readable: refuse")
    func frontmostNil() {
        #expect(!PostGuard.allowsPost(to: Self.target, frontmost: nil, targetIsRunning: true))
    }

    @Test("same bundle id but a relaunched process is not the target: refuse")
    func relaunchedProcess() {
        let relaunched = FrontmostApp(bundleId: Self.target.bundleId, processId: 101)
        #expect(!PostGuard.allowsPost(to: Self.target, frontmost: relaunched, targetIsRunning: true))
    }

    @Test("other app frontmost and target terminated: refuse")
    func bothWrong() {
        #expect(!PostGuard.allowsPost(to: Self.target, frontmost: Self.other, targetIsRunning: false))
    }

    // Worf (TASK-444, blind). Red if the comparison narrows to the pid alone (a recycled pid under another bundle).
    @Test("OC-444-W1 same pid, different bundle id is not the target: refuse")
    func samePidDifferentBundle() {
        let impostor = FrontmostApp(bundleId: "com.example.mail", processId: Self.target.processId)
        #expect(!PostGuard.allowsPost(to: Self.target, frontmost: impostor, targetIsRunning: true))
    }

    // Red if a nil bundle id stops being comparable (target without a bundle id, same pid): boundary of the equality.
    @Test("OC-444-W2 target without a bundle id, same process frontmost and running: post; terminated: refuse")
    func nilBundleIdTarget() {
        let bare = FrontmostApp(bundleId: nil, processId: 300)
        #expect(PostGuard.allowsPost(to: bare, frontmost: FrontmostApp(bundleId: nil, processId: 300), targetIsRunning: true))
        #expect(!PostGuard.allowsPost(to: bare, frontmost: FrontmostApp(bundleId: nil, processId: 300), targetIsRunning: false))
        #expect(!PostGuard.allowsPost(to: bare, frontmost: FrontmostApp(bundleId: nil, processId: 301), targetIsRunning: true))
    }

    // Red if the guard answers true for nil frontmost when the target is also gone.
    @Test("OC-444-W3 nothing frontmost and target not running: refuse")
    func nilFrontmostAndNotRunning() {
        #expect(!PostGuard.allowsPost(to: Self.target, frontmost: nil, targetIsRunning: false))
    }
}
