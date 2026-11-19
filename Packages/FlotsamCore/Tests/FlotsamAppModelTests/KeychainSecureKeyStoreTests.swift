import FlotsamBase
import Foundation
import Security
import Testing

/// TASK-498 (ADR-0011): how `KeychainSecureKeyStore` reads Keychain results. The real Keychain is never touched here:
/// `SystemKeychainKeyItem` (the SecItem calls and the this-device-only attributes) and the real LocalAuthentication
/// prompt need a person at a Mac and are checked by hand.
@Suite struct KeychainSecureKeyStoreTests {
    private final class FakeItem: KeychainKeyItem, @unchecked Sendable {
        var copyResults: [(status: OSStatus, data: Data?)]
        var addStatus: OSStatus
        private(set) var added: [Data] = []
        private(set) var copies = 0

        init(copies: [(status: OSStatus, data: Data?)], addStatus: OSStatus = errSecSuccess) {
            copyResults = copies
            self.addStatus = addStatus
        }

        func copyKey() -> (status: OSStatus, data: Data?) {
            defer { copies += 1 }
            return copyResults[min(copies, copyResults.count - 1)]
        }

        func addKey(_ key: Data) -> OSStatus {
            added.append(key)
            return addStatus
        }
    }

    private let key = Data(repeating: 7, count: 32)
    private let winner = Data(repeating: 9, count: 32)

    private func osStatus(_ result: FlotsamResult<some Any>) -> Int? {
        if case .failure(let error) = result { return error.underlying?.code }
        return nil
    }

    @Test func foundKeyIsReturned() {
        let store = KeychainSecureKeyStore(item: FakeItem(copies: [(errSecSuccess, key)]))
        #expect(store.readKey() == .success(key))
    }

    @Test func missingKeyIsSuccessWithNoKey() {
        let store = KeychainSecureKeyStore(item: FakeItem(copies: [(errSecItemNotFound, nil)]))
        #expect(store.readKey() == .success(nil))
    }

    @Test func everyOtherStatusIsAFailureNeverAMissingKey() {
        // A locked Keychain, a denied prompt, a damaged item, a missing entitlement: treating any of these as "no key"
        // would let the vault create a new key over one that exists.
        let statuses = [
            errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNotAvailable, errSecDecode,
            errSecMissingEntitlement, errSecParam, errSecIO,
        ]
        for status in statuses {
            let store = KeychainSecureKeyStore(item: FakeItem(copies: [(status, nil)]))
            let result = store.readKey()
            guard case .failure(let error) = result else { Issue.record("status \(status) read as success"); continue }
            #expect(error.code == .libDat002)
            #expect(osStatus(result) == Int(status))
        }
    }

    @Test func successWithNoDataIsAFailure() {
        let store = KeychainSecureKeyStore(item: FakeItem(copies: [(errSecSuccess, nil)]))
        guard case .failure = store.readKey() else { Issue.record("no data read as a key"); return }
    }

    @Test func addStoresAndReturnsTheKeyGiven() {
        let item = FakeItem(copies: [(errSecItemNotFound, nil)])
        #expect(KeychainSecureKeyStore(item: item).storeKeyIfAbsent(key) == .success(key))
        #expect(item.added == [key])
    }

    @Test func duplicateOnAddReturnsTheWinnersKeyNotOurs() {
        let item = FakeItem(copies: [(errSecSuccess, winner)], addStatus: errSecDuplicateItem)
        #expect(KeychainSecureKeyStore(item: item).storeKeyIfAbsent(key) == .success(winner))
        #expect(item.copies == 1, "re-read once after the duplicate")
    }

    @Test func duplicateThenUnreadableIsAFailure() {
        let item = FakeItem(copies: [(errSecAuthFailed, nil)], addStatus: errSecDuplicateItem)
        let result = KeychainSecureKeyStore(item: item).storeKeyIfAbsent(key)
        guard case .failure = result else { Issue.record("an unreadable winner was treated as stored"); return }
        #expect(osStatus(result) == Int(errSecAuthFailed))
    }

    @Test func duplicateThenGoneIsAFailureNotOurUnstoredKey() {
        let item = FakeItem(copies: [(errSecItemNotFound, nil)], addStatus: errSecDuplicateItem)
        guard case .failure = KeychainSecureKeyStore(item: item).storeKeyIfAbsent(key) else {
            Issue.record("reported a key that is not in the Keychain as stored"); return
        }
    }

    @Test func anyOtherAddFailureIsAFailureAndNeverReadsBack() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement, errSecParam] {
            let item = FakeItem(copies: [(errSecSuccess, winner)], addStatus: status)
            let result = KeychainSecureKeyStore(item: item).storeKeyIfAbsent(key)
            guard case .failure = result else { Issue.record("status \(status) read as stored"); continue }
            #expect(osStatus(result) == Int(status))
            #expect(item.copies == 0, "no second read to paper over a failed add")
        }
    }
}

/// TASK-498: `LocalAuthenticator` turns the check's outcome into the result Paste and the Shelf act on.
@Suite struct LocalAuthenticatorTests {
    @Test func aConfirmedCheckIsTheOnlySuccess() async {
        let auth = LocalAuthenticator(evaluate: { _ in nil })
        guard case .success = await auth.authenticate(reason: "copy a secure item") else {
            Issue.record("a confirmed check read as failed"); return
        }
    }

    @Test func theReasonReachesTheSystemPromptUnchanged() async {
        final class Seen: @unchecked Sendable { var reason: String? }
        let seen = Seen()
        let auth = LocalAuthenticator(evaluate: { reason in seen.reason = reason; return nil })
        _ = await auth.authenticate(reason: "copy a secure item")
        #expect(seen.reason == "copy a secure item")
    }

    @Test func cancelAndEveryFailureAreLibOs002WithTheCauseKept() async {
        for code in [-2, -1, -3, -4, -5, -6, -7, -8, -1000] {  // user cancel, auth failed, no passcode, system cancel, ...
            let auth = LocalAuthenticator(evaluate: { _ in UnderlyingErrorInfo(domain: "com.apple.LocalAuthentication", code: code) })
            guard case .failure(let error) = await auth.authenticate(reason: "r") else {
                Issue.record("code \(code) read as confirmed"); continue
            }
            #expect(error.code == .libOs002)
            #expect(error.underlying?.code == code)
        }
    }

    @Test func eachCheckAsksAgain() async {
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let auth = LocalAuthenticator(evaluate: { _ in count.n += 1; return nil })
        _ = await auth.authenticate(reason: "r")
        _ = await auth.authenticate(reason: "r")
        #expect(count.n == 2, "a confirmation is never reused")
    }
}
