import FlotsamBase
import FlotsamPaste
import Foundation
import Testing

// TASK-463 (FRD-005 section 8 "Variable help line", FR-005-17, OC-5055): the Shortcut and Trigger editor carries a
// caption that lists {date}, {time} and {clipboard} with format examples, from the catalogue.

private let helpKey = "ui.settings.editorVariablesHelp"

private func editorViewSource() throws -> String {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) { break }
        url.deleteLastPathComponent()
    }
    return try String(
        contentsOf: url.appendingPathComponent("App/Flotsam/Library/ItemBindingsEditorView.swift"), encoding: .utf8)
}

@Suite("TASK-463: editor variable help line (OC-5055)")
struct Task463VariableHelpLineTests {
    @Test("the help line names all three variables")
    func listsVariables() throws {
        let text = try #require(FlotsamStrings.text(forKey: helpKey))
        #expect(text.contains("{date}"))
        #expect(text.contains("{time}"))
        #expect(text.contains("{clipboard}"))
    }

    @Test("the help line shows a date format and a time format, and each is a valid variable")
    func formatExamplesAreReal() throws {
        let text = try #require(FlotsamStrings.text(forKey: helpKey))
        let examples = ["{date:yyyy-MM-dd}", "{time:HH:mm}"]
        for example in examples {
            #expect(text.contains(example), "missing example \(example)")
            if case .failure = TemplateVariables.validate(example) {
                Issue.record("help example \(example) is rejected by the variable grammar")
            }
        }
        // Every named variable is itself valid, so the line cannot advertise a token the engine rejects.
        for name in ["{date}", "{time}", "{clipboard}"] {
            if case .failure = TemplateVariables.validate(name) {
                Issue.record("\(name) is rejected by the variable grammar")
            }
        }
    }

    @Test("the settings enum pins the key, and the editor view shows it whether or not a trigger error is up")
    func viewShowsCaptionAlways() throws {
        #expect(SettingsString.editorVariablesHelp.key == helpKey)
        let source = try editorViewSource()
        #expect(source.contains("Text(.editorVariablesHelp)"))
        // The trigger's own help (or its inline error) stays; the variable caption is a separate line after it.
        let triggerHelp = try #require(source.range(of: "Text(.editorTriggerHelp)"))
        let variables = try #require(source.range(of: "Text(.editorVariablesHelp)"))
        #expect(triggerHelp.lowerBound < variables.lowerBound)
        #expect(!source.contains("else {\n                Text(.editorVariablesHelp)"))
    }
}
