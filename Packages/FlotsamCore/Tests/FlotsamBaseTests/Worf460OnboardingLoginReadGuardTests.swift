import Foundation
import Testing
@testable import FlotsamBase

/// TASK-460 (Worf): `OnboardingModel` lives in the app target, which no package test can instantiate, so the builder's
/// `LoginStatusReadTimingTests` proves only the predicate, not that the model consults it. Mutation: put the unguarded
/// `loginStatus = container.loginItem.status` back into `refresh()` (called from `init` on step 1) and every package
/// test stayed green. This test reads the model's source and fails if any login-item call outside the step-7 apply
/// path is not behind `OnboardingFlow.readsLoginStatus(on:)`. Source scan, because the app target has no test host
/// that may touch SMAppService (S2 owns the runtime check).
@Suite struct Worf460OnboardingLoginReadGuardTests {
    private static func modelSource() throws -> String {
        // .../Packages/FlotsamCore/Tests/FlotsamBaseTests/<this file> -> repo root is four levels up
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("App/Flotsam/OnboardingModel.swift"), encoding: .utf8)
    }

    // OC-460-01. Red if refresh() (reached from init on step 1, from the 2 s tick, and from Back/Skip) reads the login
    // item status without asking OnboardingFlow.readsLoginStatus(on:) first.
    @Test("OC-460-01: every login-item read outside applyLoginItem is behind readsLoginStatus(on:)")
    func loginItemReadsAreGuardedByTheStepRule() throws {
        // given the model source, split off the step-7-only apply path
        let source = try Self.modelSource()
        let beforeApply = try #require(source.components(separatedBy: "func applyLoginItem").first)
        let touches = beforeApply.split(separator: "\n").filter {
            $0.contains("loginItem.status") || $0.contains("loginItem.isOn") || $0.contains("loginItem.reconcile")
                || $0.contains("loginItem.setEnabled")
        }
        // when we collect every line that touches the login item outside that path
        // then there is exactly the one guarded status read, and no other touch (init included)
        #expect(touches.count == 1, "login-item touches: \(touches)")
        #expect(touches.allSatisfy { $0.contains("OnboardingFlow.readsLoginStatus(on: step)") }, "unguarded: \(touches)")
    }

    // OC-460-02. Red if init stops going through refresh() but reads the service itself, or reconcile is called early.
    @Test("OC-460-02: init body never names the login item")
    func initDoesNotTouchTheLoginItem() throws {
        let source = try Self.modelSource()
        let afterInit = try #require(source.components(separatedBy: "init(container: AppContainer, resuming: Bool) {").last)
        let initBody = try #require(afterInit.components(separatedBy: "\n    }\n").first)
        #expect(initBody.contains("refresh()"), "init no longer calls refresh(); update this test")
        #expect(!initBody.contains("loginItem"))
    }
}
