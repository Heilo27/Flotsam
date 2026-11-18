import Foundation
import Testing
@testable import FlotsamBase

/// TASK-460 / FR-008-15: the login item is registered only when the user has turned the switch on, and removed when they
/// turn it off. The fake counts calls so a test can assert that an unchecked box never reaches `register()`.
private final class CountingLoginService: LoginItemService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginItemStatus
    private var registerCalls = 0
    private var unregisterCalls = 0
    var failure: FlotsamError?
    init(_ status: LoginItemStatus) { current = status }
    var status: LoginItemStatus { lock.withLock { current } }
    var registers: Int { lock.withLock { registerCalls } }
    var unregisters: Int { lock.withLock { unregisterCalls } }
    func register() -> FlotsamResult<Void> {
        lock.withLock { registerCalls += 1 }
        return apply(.enabled)
    }
    func unregister() -> FlotsamResult<Void> {
        lock.withLock { unregisterCalls += 1 }
        return apply(.off)
    }
    func openLoginItemsSettings() {}
    private func apply(_ next: LoginItemStatus) -> FlotsamResult<Void> {
        if let failure { return .failure(failure) }
        lock.withLock { current = next }
        return .success(())
    }
}

@Suite struct LoginItemRegistrationTests {
    @Test func uncheckedWithNothingRegisteredMakesNoServiceCall() throws {
        let service = CountingLoginService(.off)
        let result = try LoginItemController(service: service).reconcile(wanted: false).get()
        #expect(service.registers == 0)
        #expect(service.unregisters == 0)
        #expect(result == .off)
    }

    @Test func checkedRegistersOnce() throws {
        let service = CountingLoginService(.off)
        let result = try LoginItemController(service: service).reconcile(wanted: true).get()
        #expect(service.registers == 1)
        #expect(service.unregisters == 0)
        #expect(result == .enabled)
    }

    @Test func uncheckedWhileRegisteredUnregistersAndNeverRegisters() throws {
        for before in [LoginItemStatus.enabled, .requiresApproval] {
            let service = CountingLoginService(before)
            let result = try LoginItemController(service: service).reconcile(wanted: false).get()
            #expect(service.registers == 0)
            #expect(service.unregisters == 1)
            #expect(result == .off)
        }
    }

    @Test func checkedWhileAlreadyOnMakesNoServiceCall() throws {
        for before in [LoginItemStatus.enabled, .requiresApproval] {
            let service = CountingLoginService(before)
            let result = try LoginItemController(service: service).reconcile(wanted: true).get()
            #expect(service.registers == 0)
            #expect(service.unregisters == 0)
            #expect(result == before)
        }
    }

    @Test func aRefusedRegisterIsSETOS001AndLeavesTheItemOff() {
        let service = CountingLoginService(.off)
        service.failure = FlotsamError(.setOs001, "register failed")
        let controller = LoginItemController(service: service)
        guard case .failure(let error) = controller.reconcile(wanted: true) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == .setOs001)
        #expect(!controller.isOn)
    }
}

/// TASK-460: S2 saw macOS record the app (a BTMManager event and the "Login Item Added" banner) about 0.4 s after first
/// launch, on onboarding step 1, with no register call. The only launch-time touch of `SMAppService` was the status
/// read in onboarding's `refresh()`; it now happens only on step 7.
@Suite struct LoginStatusReadTimingTests {
    @Test func onboardingReadsTheLoginStatusOnlyOnTheLoginStep() {
        for step in OnboardingStep.allCases {
            #expect(OnboardingFlow.readsLoginStatus(on: step) == (step == .loginItem), "step \(step)")
        }
        #expect(!OnboardingFlow.readsLoginStatus(on: .welcome))
    }
}
