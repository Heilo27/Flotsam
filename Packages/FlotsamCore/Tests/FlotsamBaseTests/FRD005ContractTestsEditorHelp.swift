import Foundation
import Testing
@testable import FlotsamBase

/// FRD-005 8T gap sweep: the editor's variable help line (OC-5055). Expected values are literals.
@Suite struct FRD005ContractTestsEditorHelp {
    // Red if the catalogue help line does not name the variable (FRD-005 UI table: "Variable help line ... lists {date},
    // {time}, {clipboard} and format examples").
    // The variables caption is its own catalogue key (TASK-463), shown under the trigger field (FRD-005 §8).
    @Test("OC-5055 the editor help line lists {date}, {time} and {clipboard}",
          arguments: ["{date}", "{time}", "{clipboard}"])
    func oc5055_helpLineListsTheVariables(variable: String) {
        // given: the catalogue text the editor's help caption renders
        let help = SettingsString.editorVariablesHelp.text
        // when / then: it names the variable
        #expect(help.contains(variable), "help line omits \(variable)")
    }

    // Red if the help key is dropped from the catalogue (the editor would show the raw key), or the key is renamed
    // without the enum following. Keeps the test above from being red for the wrong reason.
    @Test("OC-5055 the help line is a real catalogue entry, not the fallback key")
    func oc5055_helpLineIsInTheCatalogue() {
        // given: the enum case the editor view uses
        let key = SettingsString.editorVariablesHelp.key
        // when: the text is read
        let text = SettingsString.editorVariablesHelp.text
        // then: it is the catalogue text, not the key itself
        #expect(key == "ui.settings.editorVariablesHelp")
        #expect(text != key)
        #expect(!text.isEmpty)
    }
}
