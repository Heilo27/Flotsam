import Foundation
import Testing

@testable import FlotsamBase

// TASK-363 blind QA (Worf): the destructive button of the retention and image-budget confirmation (OC-7081: "The
// user clicks Delete"; DESIGN.md section 10: "Delete and Delete Items are never the default button when data loss is
// permanent"). The alert lives in the App target, so this is a source scan (precedent: Frd008ContractStringsTests).

@Suite struct Worf363StorageAlertLabelTests {
    // Red if the confirm button of the shorten / lower-budget alert is wired to any string other than a Delete label.
    @Test("OC-7081 the shorten and lower-budget confirmation's destructive button reads Delete, not Reset")
    func confirmButtonIsNotReset() throws {
        let storage = try frd008Code("App/Flotsam/Settings/StoragePane.swift")
        #expect(storage.contains("changes.confirm(change)"), "the alert must still call confirm")
        withKnownIssue("DEFECT Major: the data-deleting alert's destructive button reuses SettingsString.resetAction (\"Reset\")") {
            #expect(!storage.contains("Button(SettingsString.resetAction.text, role: .destructive) { changes.confirm(change) }"))
        }
    }
}
