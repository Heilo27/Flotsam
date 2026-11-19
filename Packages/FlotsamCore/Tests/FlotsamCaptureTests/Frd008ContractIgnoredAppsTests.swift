import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

// FRD-008 contract tests, oracle OC-8070...OC-8074 and OC-8081: the Privacy pane's ignored-apps list against the real
// capture pipeline and a real database (harness: FRD001ContractHarness.swift). The list lives in the settings
// registry; like the app container, the rig reads it live: `syncIgnored` is that one line of wiring. Expected values are
// literals from the oracle. TASK-498 (FR-008-11): the default list is now empty, so the rig seeds the six password
// managers the old default held, as a user's own list, to keep proving that a listed app's copies are dropped.

@Suite(.serialized) @MainActor struct Frd008ContractIgnoredAppsTests {
    private static let onePassword = SourceApp(bundleId: "com.1password.1password", name: "1Password")
    private static let passwords = SourceApp(bundleId: "com.apple.Passwords", name: "Passwords")
    private static let textEdit = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")

    /// The six apps the default list held before secure clips; the user's own list in these tests.
    private static let passwordManagers = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    /// Starts a rig whose ignored list is the six password managers, read live like the app container does.
    private func withRig(frontmost: SourceApp, _ body: (ContractRig) async throws -> Void) async throws {
        let rig = try await ContractRig.make(frontmost: frontmost)
        rig.settings.set(BundleIdentifierList(Self.passwordManagers), for: SettingKeys.privacyIgnoredApps)
        syncIgnored(rig)
        do { try await body(rig) } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    private func syncIgnored(_ rig: ContractRig) {
        rig.ignored = Set(rig.settings.value(SettingKeys.privacyIgnoredApps).identifiers)
    }

    /// OC-8070. 1Password on the user's list, frontmost, copies 'oracle-pw': nothing stored, no row contains it, and the skip
    /// raises no HUD and no Notice.
    /// Red if the list lacks 1Password, the skip stores the item, or the skip is surfaced to the user.
    @Test func oc8070_onePasswordCopyIsNotStored() async throws {
        try await withRig(frontmost: Self.onePassword) { rig in
            // given 1Password on the user's ignored list
            try #expect(await rig.itemCount() == 0)

            // when 1Password copies the text
            await rig.copyText("oracle-pw")

            // then delta 0, no row has the text, no search finds it, nothing was shown to the user
            try #expect(await rig.itemCount() == 0)
            try #expect(await rig.item(withText: "oracle-pw").isEmpty)
            try #expect(await rig.searchCount("oracle-pw") == 0)
            try #expect(await rig.freshItemCount() == 0)
            #expect(rig.presenter.huds.isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty)
            #expect(rig.sink.logged(.capPol002).count == 1, "the skip is recorded once, as an Info code")
        }
    }

    /// OC-8071. Passwords on the user's list, frontmost, copies 'oracle-pw2': delta 0.
    @Test func oc8071_passwordsAppCopyIsNotStored() async throws {
        try await withRig(frontmost: Self.passwords) { rig in
            // when Passwords copies the text
            await rig.copyText("oracle-pw2")

            // then nothing was stored
            try #expect(await rig.itemCount() == 0)
            try #expect(await rig.item(withText: "oracle-pw2").isEmpty)
        }
    }

    /// OC-8072. Control: TextEdit is not on the list, so its copy is stored (+1).
    /// Red if the ignore check is too broad (e.g. ignores everything once the list is non-empty).
    @Test func oc8072_textEditControlIsStored() async throws {
        try await withRig(frontmost: Self.textEdit) { rig in
            // given the list (TextEdit absent)
            #expect(!rig.ignored.contains("com.apple.TextEdit"))

            // when TextEdit copies the text
            await rig.copyText("oracle-te-1")

            // then +1 and the text is present, from the persisted store
            try #expect(await rig.itemCount() == 1)
            try #expect(await rig.item(withText: "oracle-te-1").count == 1)
            try #expect(await rig.freshItemCount() == 1)
        }
    }

    /// OC-8073. T1, T2 from TextEdit are stored; then TextEdit is added to the ignored list and copies 'oracle-te-2':
    /// T1 and T2 stay, the new copy is not stored.
    /// Red if adding to the list deletes history, or the live list is not consulted.
    @Test func oc8073_addingTextEditStopsFutureCopiesOnly() async throws {
        try await withRig(frontmost: Self.textEdit) { rig in
            // given T1 and T2 already stored from TextEdit
            await rig.copyText("oracle-T1")
            await rig.copyText("oracle-T2")
            try #expect(await rig.itemCount() == 2)

            // when TextEdit is added to the list and copies again
            rig.settings.set(rig.settings.value(SettingKeys.privacyIgnoredApps).adding("com.apple.TextEdit"), for: SettingKeys.privacyIgnoredApps)
            syncIgnored(rig)
            await rig.copyText("oracle-te-2")

            // then T1 and T2 are still present and the new copy is not stored (delta 0)
            try #expect(await rig.itemCount() == 2)
            try #expect(await rig.item(withText: "oracle-T1").count == 1)
            try #expect(await rig.item(withText: "oracle-T2").count == 1)
            try #expect(await rig.item(withText: "oracle-te-2").isEmpty)
        }
    }

    /// OC-8074. TextEdit is on the list; removing it takes the list from 7 to 6 and its next copy is stored (+1).
    @Test func oc8074_removingTextEditResumesCapture() async throws {
        try await withRig(frontmost: Self.textEdit) { rig in
            // given TextEdit ignored: its copy is dropped
            rig.settings.set(rig.settings.value(SettingKeys.privacyIgnoredApps).adding("com.apple.TextEdit"), for: SettingKeys.privacyIgnoredApps)
            syncIgnored(rig)
            #expect(rig.settings.value(SettingKeys.privacyIgnoredApps).identifiers.count == 7)
            await rig.copyText("oracle-te-0")
            try #expect(await rig.itemCount() == 0)

            // when TextEdit is removed and copies 'oracle-te-3'
            rig.settings.set(rig.settings.value(SettingKeys.privacyIgnoredApps).removing("com.apple.TextEdit"), for: SettingKeys.privacyIgnoredApps)
            syncIgnored(rig)
            await rig.copyText("oracle-te-3")

            // then the list has 6 entries without TextEdit, the Library gained exactly the new copy
            let list = rig.settings.value(SettingKeys.privacyIgnoredApps).identifiers
            #expect(list.count == 6)
            #expect(!list.contains("com.apple.TextEdit"))
            try #expect(await rig.itemCount() == 1)
            try #expect(await rig.item(withText: "oracle-te-3").count == 1)
            try #expect(await rig.item(withText: "oracle-te-0").isEmpty, "the copy made while ignored stayed dropped")
        }
    }

    /// OC-8081. The user removes all 6 defaults; the list is empty (no error), Reset to Defaults is still possible
    /// (and leaves the list empty, FR-008-11), and TextEdit's copy is stored (+1). A 1Password copy is stored too once
    /// nothing is ignored.
    @Test func oc8081_emptyListStoresEverything() async throws {
        try await withRig(frontmost: Self.textEdit) { rig in
            // given the six defaults removed one by one
            var list = rig.settings.value(SettingKeys.privacyIgnoredApps)
            #expect(list.identifiers.count == 6)
            for id in list.identifiers { list = list.removing(id) }
            rig.settings.set(list, for: SettingKeys.privacyIgnoredApps)
            syncIgnored(rig)
            #expect(rig.settings.value(SettingKeys.privacyIgnoredApps).identifiers.isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty, "no error for an empty list")

            // when TextEdit copies 'oracle-e1'
            await rig.copyText("oracle-e1")

            // then the copy is stored (+1)
            try #expect(await rig.itemCount() == 1)
            try #expect(await rig.item(withText: "oracle-e1").count == 1)

            // and Reset to Defaults leaves the list empty (FR-008-11), so a 1Password copy is stored too
            rig.settings.set(SettingKeys.privacyIgnoredApps.defaultValue, for: SettingKeys.privacyIgnoredApps)
            syncIgnored(rig)
            #expect(rig.ignored.isEmpty)
            rig.sourceApps.frontmost = Self.onePassword
            await rig.copyText("oracle-e2")
            try #expect(await rig.itemCount() == 2, "after reset no app is ignored, so the password manager's copy is stored")
        }
    }
}
