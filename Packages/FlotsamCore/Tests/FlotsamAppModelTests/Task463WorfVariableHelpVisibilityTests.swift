import Foundation
import Testing

// TASK-463 Worf blind QA (FRD-005 section 8 "Variable help line", FR-005-17, OC-5055).
// The variable help caption must show whether or not the trigger field has an inline error. The editor view has no
// render harness, so this checks the view's structure: the caption must be a direct child of the trigger row's VStack
// (a sibling of the LabeledContent), never nested inside the `if let message ... else { ... }` that swaps the error
// for the trigger help. Whitespace-independent, unlike a text match on indentation.

private func triggerRowBody() throws -> String {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) { break }
        url.deleteLastPathComponent()
    }
    let source = try String(
        contentsOf: url.appendingPathComponent("App/Flotsam/Library/ItemBindingsEditorView.swift"), encoding: .utf8)
    let code = source.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    let start = try #require(code.range(of: "private var triggerRow"))
    return String(code[start.lowerBound...])
}

/// Brace depth just before `marker`, counted from the start of the triggerRow declaration.
private func depth(of marker: String, in text: String) throws -> Int {
    let range = try #require(text.range(of: marker), "\(marker) not found in triggerRow")
    var depth = 0
    for ch in text[..<range.lowerBound] {
        if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
    }
    return depth
}

@Suite("TASK-463 (Worf): variable help caption visibility (OC-5055)")
struct Task463WorfVariableHelpVisibilityTests {
    @Test("the caption is a direct child of the trigger row, beside the field, outside the error/help branch")
    func captionIsUnconditional() throws {
        // given: the trigger row source
        let body = try triggerRowBody()
        // when: depths of the field, the error branch and the caption are measured
        let field = try depth(of: "LabeledContent", in: body)
        let errorBranch = try depth(of: "if let message = model.triggerErrorMessage", in: body)
        let caption = try depth(of: "Text(.editorVariablesHelp)", in: body)
        // then: all three are siblings, so the caption shows with a trigger error and without one
        #expect(caption == field, "caption nested at depth \(caption), field at \(field)")
        #expect(caption == errorBranch, "caption is not a sibling of the error/help branch")
    }

    @Test("the caption is rendered exactly once in the editor row (no duplicate in a branch)")
    func captionAppearsOnce() throws {
        let body = try triggerRowBody()
        #expect(body.components(separatedBy: "Text(.editorVariablesHelp)").count - 1 == 1)
    }

    @Test("the trigger's own error and help lines are still present (the caption did not replace them)")
    func triggerLinesSurvive() throws {
        let body = try triggerRowBody()
        #expect(body.contains("Text(verbatim: message)"))
        #expect(body.contains("Text(.editorTriggerHelp)"))
    }
}
