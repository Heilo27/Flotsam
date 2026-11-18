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
}
