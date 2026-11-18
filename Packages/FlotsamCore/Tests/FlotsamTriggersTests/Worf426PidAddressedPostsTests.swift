import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

// TASK-426 (Worf, blind): security F4b. Contract: FR-005-14 (every key post of the expansion is addressed to the process
// the trigger was typed into; immediately before each post the target must still be frontmost, else nothing is posted
// for that call) and FR-005-15 (failure paths, (e) no restore on failure, (b) log by code only), ADR-0005.
// The fake poster mirrors the adapter's frontmost check, so these tests pin the EXPANDER's side of the contract: it
// names the target on every call and stops posting when a post is refused. The adapter's own re-check lives in
// App/Platform/CGEventKeyPoster.swift, which has no test target.

@MainActor
@Suite("TASK-426 pid-addressed trigger posts")
struct Worf426PidAddressedPostsTests {
    private static let space = TriggerKeys.space
    private static let backspace = TriggerKeys.backspace
    private static let other = FrontmostApp(bundleId: "com.example.other", processId: 200)
    /// A target that is neither the harness default nor the "other" app, so a hard-coded pid cannot pass.
    private static let target = FrontmostApp(bundleId: "com.example.terminal", processId: 4242)

    private func harness(failPaste: Bool = false) -> ExpanderHarness {
        let h = ExpanderHarness(
            content: .success(ItemContent(kind: .text, plainText: "ITEMTEXT-9f3", representations: [], members: [])))
        h.environment.frontmost = Self.target
        h.keys.failPaste = failPaste
        return h
    }

    private func flip(_ h: ExpanderHarness, whenActionCountIs n: Int) {
        let environment = h.environment
        h.keys.beforePost = {
            if h.keys.actions.count == n { environment.frontmost = Self.other }
        }
    }

    // MARK: Every post is addressed

    /// OC-426-01. given a match typed into pid 4242, when the expansion succeeds, then both posts (Backspaces, ⌘V)
    /// carry pid 4242. Red if step 5 drops `to: match.app` or passes another app.
    @Test("OC-426-01 success path: Backspaces and paste both addressed to the match app")
    func successPostsAddressed() async {
        let h = harness()
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .expanded)
        #expect(h.keys.actions == [.key(Self.backspace, count: 3), .paste])
        #expect(h.keys.targets == [Self.target, Self.target])
    }

    /// OC-426-02. given a failed paste, when the abort re-types and re-posts the boundary, then all four posts (Backspaces,
    /// ⌘V, text, boundary) are addressed to pid 4242. Red if postText or repostBoundary loses the target.
    @Test("OC-426-02 failed-paste path: all four post kinds addressed to the match app")
    func failedPasteAllFourAddressed() async {
        let h = harness(failPaste: true)
        _ = await h.expander.expand(h.match(app: Self.target))
        #expect(h.keys.actions == [.key(Self.backspace, count: 3), .paste, .text("sig"), .key(Self.space, count: 1)])
        #expect(h.keys.targets == Array(repeating: Self.target, count: 4))
    }

    /// OC-426-03. given a step 1 failure (item load fails), when the boundary key is re-posted, then it is addressed to
    /// the match app. Red if the pre-delete repost is unaddressed.
    @Test("OC-426-03 pre-delete abort: boundary repost addressed to the match app")
    func preDeleteRepostAddressed() async {
        let h = ExpanderHarness(content: .failure(FlotsamError(.libIo001, "forced")))
        h.environment.frontmost = Self.target
        _ = await h.expander.expand(h.match(boundary: TriggerKeys.tab, app: Self.target))
        #expect(h.keys.actions == [.key(TriggerKeys.tab, count: 1)])
        #expect(h.keys.targets == [Self.target])
    }

    /// OC-426-04. given the match app differs from the frontmost app at the post, when the expansion runs, then the
    /// refusing poster records no post at all (the expander never retargets to the frontmost app).
    @Test("OC-426-04 match app not frontmost: nothing posted to anyone")
    func matchAppNotFrontmostPostsNothing() async {
        let h = harness()
        h.environment.frontmost = Self.other
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions.isEmpty)
        #expect(h.keys.targets.isEmpty)
    }

    // MARK: Focus change at each step boundary

    /// OC-426-05. given focus changes after the step 2 check but before the Backspaces, then no post of any kind happens,
    /// nothing is written to the store, one HUD.
    @Test("OC-426-05 boundary A: focus change before the Backspaces stops everything")
    func focusChangeBeforeBackspaces() async {
        let h = harness()
        flip(h, whenActionCountIs: 0)
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions.isEmpty)
        #expect(h.store.recorded.isEmpty)
        #expect(h.presenter.huds.count == 1)
    }

    /// OC-426-06. given focus changes between the Backspaces and the paste (after the expander's own wait passed), then
    /// ⌘V is refused and neither text nor boundary key is posted. Red if the paste is not target-checked at post time or
    /// the abort re-posts into the new app.
    @Test("OC-426-06 boundary B: focus change between the Backspaces and the paste")
    func focusChangeBeforePaste() async {
        let h = harness()
        flip(h, whenActionCountIs: 1)
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(Self.backspace, count: 3)])
        #expect(h.store.recorded.isEmpty)
        #expect(h.presenter.huds.count == 1)
    }

    /// OC-426-07. given a failed paste and focus changing just before the re-type, then neither the text nor the boundary
    /// key is posted. Red if the re-type or the repost skips the post-time check.
    @Test("OC-426-07 boundary C: focus change before the re-type")
    func focusChangeBeforeRetype() async {
        let h = harness(failPaste: true)
        flip(h, whenActionCountIs: 2)
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(Self.backspace, count: 3), .paste])
        #expect(h.keys.targets == [Self.target, Self.target])
        #expect(h.presenter.huds.count == 1)
    }

    /// OC-426-08. given a failed paste and focus changing just after the re-type, then the boundary key is not posted.
    @Test("OC-426-08 boundary D: focus change before the boundary repost")
    func focusChangeBeforeBoundaryRepost() async {
        let h = harness(failPaste: true)
        flip(h, whenActionCountIs: 3)
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(Self.backspace, count: 3), .paste, .text("sig")])
        #expect(h.presenter.huds.count == 1)
    }

    /// OC-426-09. given focus changing before the pre-delete boundary repost (load failed), then nothing is posted.
    @Test("OC-426-09 boundary E: focus change before the pre-delete boundary repost")
    func focusChangeBeforePreDeleteRepost() async {
        let h = ExpanderHarness(content: .failure(FlotsamError(.libIo001, "forced")))
        h.environment.frontmost = Self.target
        flip(h, whenActionCountIs: 0)
        _ = await h.expander.expand(h.match(app: Self.target))
        #expect(h.keys.actions.isEmpty)
    }

    // MARK: Target quit

    /// OC-426-10. given the target quits during the item load (no frontmost app at all), then nothing is posted and the
    /// HUD shows. A quit mid-sequence is the same to the poster: frontmost no longer equals the target.
    @Test("OC-426-10 target quit before the sequence: nothing posted")
    func targetQuitBeforeSequence() async {
        let h = harness()
        h.environment.frontmost = nil
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions.isEmpty)
        #expect(h.presenter.huds.count == 1)
    }

    /// OC-426-11. given the target quits right after the Backspaces were posted, then no ⌘V, text or boundary key is
    /// posted.
    @Test("OC-426-11 target quit after the Backspaces: nothing more posted")
    func targetQuitAfterBackspaces() async {
        let h = harness()
        let environment = h.environment
        h.keys.beforePost = { if h.keys.actions.count == 1 { environment.frontmost = nil } }
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(Self.backspace, count: 3)])
    }

    // MARK: Clipboard and logging on an aborted expansion

    /// OC-426-12. given the abort comes after the Backspaces (FR-005-15 e), then the previous clipboard is NOT restored:
    /// exactly one pasteboard write (the item), the item stays on the pasteboard. Red if an abort path restores.
    @Test("OC-426-12 FR-005-15(e): abort after the Backspaces leaves the item on the pasteboard, no restore")
    func abortAfterBackspacesDoesNotRestore() async {
        let h = harness()
        flip(h, whenActionCountIs: 1)
        _ = await h.expander.expand(h.match(app: Self.target))
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.pasteboard.plainText == "ITEMTEXT-9f3")
    }

    /// OC-426-13. given the Backspaces are refused (focus changed first), then the same: item stays, no restore.
    @Test("OC-426-13 FR-005-15(e): abort before the Backspaces leaves the item on the pasteboard, no restore")
    func abortBeforeBackspacesDoesNotRestore() async {
        let h = harness()
        flip(h, whenActionCountIs: 0)
        _ = await h.expander.expand(h.match(app: Self.target))
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.pasteboard.plainText == "ITEMTEXT-9f3")
    }

    /// OC-426-14. given every post succeeded and focus then moves on (after ⌘V), then the expansion still counts as
    /// expanded and the previous clipboard IS restored (FR-005-16): two writes, previous text back.
    @Test("OC-426-14 completed expansion restores the previous clipboard even if focus moves afterwards")
    func completedExpansionRestores() async {
        let h = harness()
        let environment = h.environment
        h.keys.onAction = { if h.keys.actions.count == 2 { environment.frontmost = Self.other } }
        let outcome = await h.expander.expand(h.match(app: Self.target))
        #expect(outcome == .expanded)
        #expect(h.pasteboard.writes.count == 2)
        #expect(h.pasteboard.plainText == "previous clipboard")
        #expect(h.store.recorded == [ExpanderHarness.itemId])
    }

    /// OC-426-15. given an aborted expansion, when it is logged, then exactly one TRG-OS-002 error record exists, one HUD
    /// is shown, the reporter holds [TRG-OS-002], and neither the typed trigger nor the item text appears in any log text
    /// (FR-005-15 b, FR-000-10).
    @Test("OC-426-15 aborted expansion logs TRG-OS-002 once, by code only")
    func abortedExpansionLogsByCodeOnly() async {
        let h = ExpanderHarness(
            content: .success(ItemContent(kind: .text, plainText: "ITEMTEXT-9f3", representations: [], members: [])))
        h.environment.frontmost = Self.target
        flip(h, whenActionCountIs: 1)
        let outcome = await h.expander.expand(h.match(typed: ";zq7x", app: Self.target))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.sink.records.filter { $0.headline.hasPrefix("TRG-OS-002") }.count == 1)
        #expect(await h.reportedCodes() == [.trgOs002])
        #expect(h.presenter.huds.count == 1)
        #expect(!h.sink.allText.contains("zq7x"))
        #expect(!h.sink.allText.contains("ITEMTEXT-9f3"))
        // Not logged as a match: no `trigger.matched true` event for an expansion that did not complete.
        #expect(h.store.recorded.isEmpty)
    }
}
