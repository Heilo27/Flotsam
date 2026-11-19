import FlotsamBase
import Foundation
import LocalAuthentication

/// `UserAuthenticator` over LocalAuthentication: the device owner confirms with Touch ID, Apple Watch or the account
/// password (`.deviceOwnerAuthentication`, FR-003-23, FR-006-21). The decision lives in `authenticate`: a confirmed
/// check is the only success, and every other outcome (cancel, failure, no password set, no UI available) is
/// `LIB-OS-002`. The caller never needs to tell them apart, and a surprising LocalAuthentication outcome must never be
/// read as a yes.
///
/// Not unit tested against the real thing: the prompt needs a person. `authenticate` is tested with a stand-in
/// `evaluate`; `systemEvaluate` is the only code that touches LocalAuthentication.
struct LocalAuthenticator: UserAuthenticator {
    /// Runs the check. nil means the owner confirmed; otherwise the failure's domain and code (never its text).
    typealias Evaluate = @Sendable (_ reason: String) async -> UnderlyingErrorInfo?

    private let evaluate: Evaluate

    init(evaluate: @escaping Evaluate = LocalAuthenticator.systemEvaluate) { self.evaluate = evaluate }

    func authenticate(reason: String) async -> FlotsamResult<Void> {
        if let cause = await evaluate(reason) {
            return .failure(FlotsamError(.libOs002, "The owner did not confirm a secure item", underlying: cause))
        }
        return .success(())
    }

    /// A new context per check, with reuse switched off, so no earlier confirmation can answer this one: every paste of
    /// a secure item prompts (FR-003-23). A context that has already evaluated once would remember its result.
    static func systemEvaluate(reason: String) async -> UnderlyingErrorInfo? {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? nil : UnderlyingErrorInfo(domain: LAError.errorDomain, code: LAError.authenticationFailed.rawValue)
        } catch {
            return UnderlyingErrorInfo(error)
        }
    }
}
